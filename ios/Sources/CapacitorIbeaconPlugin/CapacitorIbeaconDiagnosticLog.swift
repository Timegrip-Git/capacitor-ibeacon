import Foundation

/*
  TEMPORARY diagnostics, off unless the host app turns them on through start(diagnosticLogFile:).

  Everything this plugin says goes to NSLog, which can only be read while something is attached to
  the console - and the events that matter most here cannot be observed that way. A crossing is
  delivered to a backgrounded process while the phone is being carried away from the beacon, and
  `devicectl --console` reaches the device over a network tunnel that dies the moment that walk
  disturbs the Wi-Fi link, taking the log of the walk with it. Worse, the disconnect looks like
  silence: indistinguishable from the beacon never being heard, which is the very thing under
  investigation.

  A file in the app container survives the disconnect, the backgrounding and the termination, and is
  fetched afterwards over a connection that only has to hold for a second:

    xcrun devicectl device copy from --device <UDID> \
      --domain-type appDataContainer --domain-identifier <bundle id> \
      --source Documents/beacon.log --destination ./beacon.log

  Public so that the host app can write its own lines here too. Interleaving them is the point: what
  report(_:state:fromCrossing:) decided to announce and what the app then did with it are only
  debuggable together, as one ordered sequence.
*/
public enum CapacitorIbeaconDiagnosticLog {

    private static let fileName = "beacon.log"

    /*
      Rotated rather than truncated, and one generation is kept.

      A session worth reading can be an hour of walking, and the interesting moment is usually at the
      end of it - but the state a region started that session with is at the beginning, so throwing
      away the older half is exactly wrong. Rotating keeps both halves reachable while bounding what
      the plugin can leave in someone's app container.
    */
    private static let maximumBytes: UInt64 = 4 * 1024 * 1024

    /*
      Serial, and the only thread that touches the state below.

      Core Location does not promise which thread a delegate callback arrives on - applicationStateName()
      already hops to the main thread precisely because they do not all land there - so two callbacks
      landing together must not interleave halfway through a line. DateFormatter is not thread-safe
      either, and is confined here for the same reason.
    */
    private static let queue = DispatchQueue(label: "ee.capgo.capacitor-ibeacon.diagnostic-log")

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Deliberately the shape NSLog prints, so a line from the file and a line from the console
        // can be compared without converting anything.
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static var didAnnounceProcess = false
    // Tracked rather than stat()ed per line, and seeded from the file at the first write of each
    // process. Only the rotation decision needs it, and it may be off by whatever another process
    // wrote concurrently - which cannot happen, there being one app process at a time.
    private static var bytesWritten: UInt64 = 0

    /// Whether anything is written to the file at all. Off by default; see `CapacitorIbeacon.start`.
    public static var isEnabled = false

    /// Where the log is written, for a host app that wants to attach or clear it. Nil only if the
    /// container has no Documents directory, which does not happen on iOS.
    public static var fileURL: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent(fileName)
    }

    /*
      Logs to NSLog exactly as before, and to the file while it is enabled.

      This is what the plugin's own log sites reach through beaconLog below, and it is public so that
      the host app's beacon logging can land in the same file. Interleaving is the point: what
      report(_:state:fromCrossing:) decided to announce and what the app then did with it are only
      debuggable together, as one ordered sequence.
    */
    public static func log(_ format: String, _ arguments: CVarArg...) {
        emit(format, arguments)
    }

    // The array-taking half, so that the variadic entry points above and in beaconLog can both
    // forward to it - a Swift variadic cannot be passed on to another variadic.
    static func emit(_ format: String, _ arguments: [CVarArg]) {
        withVaList(arguments) { NSLogv(format, $0) }

        // Checked before formatting, not inside write(): rendering is the expensive half, and while
        // the file is off this has to cost no more than the NSLog above.
        guard isEnabled else { return }
        let rendered = withVaList(arguments) { NSString(format: format, arguments: $0) as String }
        write(rendered)
    }

    /// Appends one line. Safe to call from any thread, and does nothing while disabled.
    public static func write(_ message: String) {
        guard isEnabled else { return }
        // Stamped here rather than on the queue: the timestamp is meant to say when the event
        // happened, not when the writer got round to it.
        let timestamp = Date()
        queue.async { append(message, at: timestamp) }
    }

    /// Removes the log and its rotated generation, for a host app that wants each test run to start
    /// from an empty file rather than reading back through the previous one.
    public static func reset() {
        queue.async {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL(for: url))
            bytesWritten = 0
            didAnnounceProcess = false
        }
    }

    // Blocks until everything already queued has reached the file. Internal, not part of the plugin
    // API: only the tests need it, to read back a file the writer reaches asynchronously.
    static func flush() {
        queue.sync { }
    }

    private static func append(_ message: String, at timestamp: Date) {
        guard let url = fileURL else { return }

        if !didAnnounceProcess {
            didAnnounceProcess = true
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            bytesWritten = (attributes?[.size] as? UInt64) ?? 0

            /*
              Core Location relaunches the app in the background to deliver a crossing, so one file
              spans many processes - and the plugin's own logging says so nowhere, because within a
              process there is nothing to say. Without this marker the boundary is invisible, and the
              emptiness a relaunched process starts with is what decides whether the event arriving
              moments later is announced or swallowed. The pid matches the one NSLog prints.
            */
            appendLine("--- process \(ProcessInfo.processInfo.processIdentifier) started ---", to: url, at: timestamp)
        }

        appendLine(message, to: url, at: timestamp)
    }

    private static func appendLine(_ message: String, to url: URL, at timestamp: Date) {
        // Here rather than in append(), so that the process marker above is also subject to it and
        // cannot be written to a file that is about to be rotated out from under it.
        if bytesWritten > maximumBytes {
            rotate(url)
        }

        let line = "\(timestampFormatter.string(from: timestamp)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        defer { bytesWritten += UInt64(data.count) }

        guard FileManager.default.fileExists(atPath: url.path) else {
            // Created rather than assumed. Documents exists in a real app container, but not in the
            // test bundle - and every failure on this path is swallowed by a `try?`, so a missing
            // directory would make the log silently empty exactly where silence is the symptom
            // being investigated.
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        // write(2) reaches the file as it returns, so being killed mid-walk costs nothing already
        // logged - which is the whole reason for writing here instead of streaming.
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func rotate(_ url: URL) {
        let previous = rotatedURL(for: url)
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        bytesWritten = 0
    }

    private static func rotatedURL(for url: URL) -> URL {
        return url.deletingLastPathComponent().appendingPathComponent("\(fileName).1")
    }
}

/*
  The one funnel every log site in this plugin goes through: NSLog exactly as before, plus the file
  when it is enabled.

  A free function rather than a method so that the call sites need nothing from `self` - one of them
  logs from inside a `[weak self]` closure, where routing through the instance would mean the line
  going missing in precisely the case the log exists to explain.
*/
func beaconLog(_ format: String, _ arguments: CVarArg...) {
    CapacitorIbeaconDiagnosticLog.emit(format, arguments)
}
