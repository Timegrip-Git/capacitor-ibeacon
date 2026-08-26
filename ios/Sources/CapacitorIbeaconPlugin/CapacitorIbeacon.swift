import Foundation
import CoreLocation
import CoreBluetooth

public class CapacitorIbeacon: NSObject, CLLocationManagerDelegate, CBPeripheralManagerDelegate {

    /*
      One instance per process, not one per bridge.

      Core Location keeps monitoring the app's regions after the app is terminated, and relaunches it
      in the background to deliver a crossing - within moments, and long before a Capacitor bridge,
      its WebView and a remote frontend could be ready. A CLLocationManager created with the bridge
      therefore does not exist when the event arrives, and the event is delivered nowhere and lost.

      So monitoring lives for as long as the process does, and the bridge attaches to it when there
      happens to be one - the counterpart of holding the scan state in statics on Android, where the
      Activity comes and goes while the foreground service keeps the scan alive. start() is called
      from the host app's AppDelegate, before any bridge exists.
    */
    public static let shared = CapacitorIbeacon()

    private var locationManager: CLLocationManager!
    private var peripheralManager: CBPeripheralManager!
    private weak var plugin: CapacitorIbeaconPlugin?
    private var monitoredRegions: [String: CLBeaconRegion] = [:]
    private var rangedRegions: [String: CLBeaconRegion] = [:]
    private var peripheralManagerReadyCallbacks: [(CBPeripheralManager) -> Void] = []
    // The first CBPeripheralManager of an app's life also waits for the user to answer the Bluetooth
    // prompt, which takes longer than a few seconds. Too short a timeout reports the .unknown state
    // as "Bluetooth is off" while it is merely undecided.
    private let peripheralManagerStateTimeout: TimeInterval = 30.0

    // Last state reported for a monitored region, so that enter and exit stay transitions rather
    // than repeats - see report(_:state:fromCrossing:).
    private var monitoredRegionStates: [String: CLRegionState] = [:]
    private let initialStateRetryDelay: TimeInterval = 3.0

    /*
      TEMPORARY diagnostics, off unless the host app sets it.

      Monitoring only speaks when Core Location decides a boundary was crossed, so silence is
      ambiguous: it means either "the beacons were never heard" or "they were heard throughout and
      no crossing was declared". Ranging reports continuously and tells those apart - the same
      question the per-detection log answered on Android, where the beacons turned out to be heard
      every 1.3s while exits were being declared anyway.
    */
    public var diagnosticRangingEnabled = false
    private var lastRangeLog: [String: Date] = [:]
    private let rangeLogInterval: TimeInterval = 20

    private var authorizationCallbacks: [(String) -> Void] = []
    private var authorizationTarget: CLAuthorizationStatus?
    private let authorizationTimeout: TimeInterval = 60.0

    override public init() {
        super.init()
        locationManager = CLLocationManager()
        locationManager.delegate = self
        // peripheralManager intentionally not constructed here - see withReadyPeripheralManager().
    }

    /*
      Called from the host app's AppDelegate on every launch, background relaunches included, so that
      a delegate is in place before Core Location delivers anything. Regions monitored before the app
      was terminated are adopted from Core Location itself, which persists them - so monitoring
      re-asserts on launch without the frontend having to ask, and keeps working even if the frontend
      never loads.

      Their state is left unknown on purpose. Nothing may be announced merely because the app started:
      an event is reported when Core Location reports a crossing, and a determination only confirms a
      state that was already known - see report(_:state:fromCrossing:).
    */
    public func start(diagnosticRanging: Bool = false) {
        diagnosticRangingEnabled = diagnosticRanging

        /*
          iOS declines to monitor beacon regions on reduced accuracy, and says so nowhere - which
          looks exactly like a beacon that is never heard. Worth stating at launch, since it is a
          Settings toggle rather than anything the code can fix.
        */
        let accuracy: String
        if #available(iOS 14.0, *) {
            accuracy = locationManager.accuracyAuthorization == .fullAccuracy ? "full" : "REDUCED"
        } else {
            accuracy = "full"
        }
        NSLog("CapacitorIbeacon: authorization %@, accuracy %@, bluetooth-dependent monitoring",
              getAuthorizationStatus(), accuracy)

        var adopted: [String] = []
        for region in locationManager.monitoredRegions {
            guard let beaconRegion = region as? CLBeaconRegion else { continue }
            monitoredRegions[beaconRegion.identifier] = beaconRegion
            adopted.append(beaconRegion.identifier)
        }

        if diagnosticRangingEnabled {
            for (identifier, region) in monitoredRegions {
                locationManager.startRangingBeacons(in: region)
                NSLog("CapacitorIbeacon: diagnostic ranging started for %@ (adopted)", identifier)
            }
        }

        // Also the marker for "is this build running the process-scoped monitoring?", which is
        // otherwise unanswerable from outside: Swift method names are mangled away in a release
        // binary, so only a string literal like this one survives to be grepped for in an .ipa.
        NSLog("CapacitorIbeacon: monitoring started for the process, adopted %d region(s): %@",
              adopted.count, adopted.joined(separator: ", "))
    }

    // The bridge that is currently alive, or nil while none is - JS events are routed through it and
    // dropped when there is none, while the native broadcast below happens either way.
    public func setPlugin(_ plugin: CapacitorIbeaconPlugin?) {
        self.plugin = plugin
    }

    public func isCurrentPlugin(_ candidate: CapacitorIbeaconPlugin) -> Bool {
        return plugin === candidate
    }

    // Merely instantiating CBPeripheralManager triggers the Bluetooth permission prompt, so
    // construction is deferred to here rather than init(). Its state also starts .unknown and
    // only settles asynchronously via peripheralManagerDidUpdateState() below, so `body` waits
    // for that instead of seeing a stale .unknown - with a timeout in case it never settles.
    private func withReadyPeripheralManager(_ body: @escaping (CBPeripheralManager) -> Void) {
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }

        if peripheralManager.state != .unknown {
            body(peripheralManager)
            return
        }

        peripheralManagerReadyCallbacks.append(body)

        DispatchQueue.main.asyncAfter(deadline: .now() + peripheralManagerStateTimeout) { [weak self] in
            guard let self = self, !self.peripheralManagerReadyCallbacks.isEmpty else { return }
            let callbacks = self.peripheralManagerReadyCallbacks
            self.peripheralManagerReadyCallbacks.removeAll()
            callbacks.forEach { $0(self.peripheralManager) }
        }
    }

    public func startMonitoringForRegion(identifier: String, uuid: String, major: Int?, minor: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        let beaconRegion: CLBeaconRegion
        if let major = major {
            if let minor = minor {
                beaconRegion = CLBeaconRegion(uuid: beaconUUID, major: CLBeaconMajorValue(major), minor: CLBeaconMinorValue(minor), identifier: identifier)
            } else {
                beaconRegion = CLBeaconRegion(uuid: beaconUUID, major: CLBeaconMajorValue(major), identifier: identifier)
            }
        } else {
            beaconRegion = CLBeaconRegion(uuid: beaconUUID, identifier: identifier)
        }

        beaconRegion.notifyEntryStateOnDisplay = true
        beaconRegion.notifyOnEntry = true
        beaconRegion.notifyOnExit = true

        /*
          Whether this region is new to us decides whether its current state is worth asking for.

          Core Location keeps monitoring across launches, and a frontend re-asserts its monitoring on
          every app start, so most calls here re-register something already being watched. Asking for
          the state then would report being inside a region that was entered long ago - an event that
          says nothing except that the app started, and one that arrives again on every launch.

          A region already in Core Location's own monitoredRegions counts as known even if this
          process has never seen it, which is what makes a relaunch silent. Same identifier but
          different identifiers means a different region, and it is new again.
        */
        let alreadyMonitored = locationManager.monitoredRegions.contains { existing in
            guard let existing = existing as? CLBeaconRegion else { return false }
            return existing.identifier == identifier && existing == beaconRegion
        }

        if !alreadyMonitored {
            // Seeded rather than cleared: the requestState() below then answers as a transition into
            // the region, which is the one enter the user should get - while a determination arriving
            // with nothing remembered stays silent, see report(_:state:fromCrossing:).
            monitoredRegionStates[identifier] = .outside
        }

        monitoredRegions[identifier] = beaconRegion
        locationManager.startMonitoring(for: beaconRegion)

        /*
          Core Location reports boundary crossings only, so a region selected while already inside it
          would stay silent until it was left and re-entered. Android reports it as soon as the beacon
          is heard, so the state is asked for outright - but only for a region that is genuinely new,
          which is the one case where the answer is news rather than a restatement.

          Asked twice, because a beacon region's state comes back .unknown until the OS has had a
          chance to scan - the retry only fires while nothing definite has arrived.
        */
        if diagnosticRangingEnabled {
            locationManager.startRangingBeacons(in: beaconRegion)
            NSLog("CapacitorIbeacon: diagnostic ranging started for %@", identifier)
        }

        if !alreadyMonitored {
            locationManager.requestState(for: beaconRegion)
            DispatchQueue.main.asyncAfter(deadline: .now() + initialStateRetryDelay) { [weak self] in
                guard let self = self,
                      let region = self.monitoredRegions[identifier],
                      self.monitoredRegionStates[identifier] == nil else { return }
                self.locationManager.requestState(for: region)
            }
        }

        completion(.success(()))
    }

    public func stopMonitoringForRegion(identifier: String, uuid: String) {
        if let region = monitoredRegions[identifier] {
            locationManager.stopMonitoring(for: region)
            monitoredRegions.removeValue(forKey: identifier)
            monitoredRegionStates.removeValue(forKey: identifier)
        }
    }

    public func startRangingBeaconsInRegion(identifier: String, uuid: String, major: Int?, minor: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        let beaconRegion: CLBeaconRegion
        if let major = major {
            if let minor = minor {
                beaconRegion = CLBeaconRegion(uuid: beaconUUID, major: CLBeaconMajorValue(major), minor: CLBeaconMinorValue(minor), identifier: identifier)
            } else {
                beaconRegion = CLBeaconRegion(uuid: beaconUUID, major: CLBeaconMajorValue(major), identifier: identifier)
            }
        } else {
            beaconRegion = CLBeaconRegion(uuid: beaconUUID, identifier: identifier)
        }

        rangedRegions[identifier] = beaconRegion
        locationManager.startRangingBeacons(in: beaconRegion)
        completion(.success(()))
    }

    public func stopRangingBeaconsInRegion(identifier: String, uuid: String) {
        if let region = rangedRegions[identifier] {
            locationManager.stopRangingBeacons(in: region)
            rangedRegions.removeValue(forKey: identifier)
        }
    }

    public func startAdvertising(uuid: String, major: Int, minor: Int, identifier: String, measuredPower: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        let beaconRegion = CLBeaconRegion(uuid: beaconUUID, major: CLBeaconMajorValue(major), minor: CLBeaconMinorValue(minor), identifier: identifier)

        withReadyPeripheralManager { manager in
            guard manager.state == .poweredOn else {
                let error = NSError(domain: "CapacitorIbeacon", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bluetooth is not powered on"])
                completion(.failure(error))
                return
            }

            if let power = measuredPower {
                manager.startAdvertising(beaconRegion.peripheralData(withMeasuredPower: NSNumber(value: power)) as? [String: Any])
            } else {
                manager.startAdvertising(beaconRegion.peripheralData(withMeasuredPower: nil) as? [String: Any])
            }

            completion(.success(()))
        }
    }

    public func stopAdvertising() {
        // Not ensurePeripheralManager(): stopping something that was never started shouldn't
        // newly construct (and trigger a permission prompt for) a manager that doesn't exist yet.
        peripheralManager?.stopAdvertising()
    }

    /*
      Both of these prompt the user, and the answer arrives on the authorization delegate rather than
      from the call - so the completion is held until it does. Reading the status straight after
      asking, as this used to, reports whatever it was beforehand: "not_determined" on a first run,
      which a caller that requires authorization then treats as a refusal.

      Requesting "always" can also be answered in two steps: iOS may grant when-in-use first and
      upgrade later. A status that is not yet the one asked for is therefore not final, and the
      completion keeps waiting - up to a timeout, since the user may simply never decide, and iOS
      delivers nothing at all when the prompt is suppressed for having been answered before.
    */
    public func requestWhenInUseAuthorization(completion: @escaping (String) -> Void) {
        requestAuthorization(target: .authorizedWhenInUse, completion: completion) {
            self.locationManager.requestWhenInUseAuthorization()
        }
    }

    public func requestAlwaysAuthorization(completion: @escaping (String) -> Void) {
        requestAuthorization(target: .authorizedAlways, completion: completion) {
            self.locationManager.requestAlwaysAuthorization()
        }
    }

    private func requestAuthorization(
        target: CLAuthorizationStatus,
        completion: @escaping (String) -> Void,
        request: @escaping () -> Void
    ) {
        let current = currentAuthorizationStatus()

        // Already answered - asking again shows nothing and reports nothing.
        if current != .notDetermined, current == target || target == .authorizedWhenInUse {
            completion(getAuthorizationStatus())
            return
        }

        authorizationTarget = target
        authorizationCallbacks.append(completion)
        request()

        DispatchQueue.main.asyncAfter(deadline: .now() + authorizationTimeout) { [weak self] in
            guard let self = self, !self.authorizationCallbacks.isEmpty else { return }
            self.settleAuthorization()
        }
    }

    /*
      iOS will not monitor an iBeacon region on reduced accuracy, and says so nowhere: no error, no
      monitoringDidFail, just permanent silence that is indistinguishable from a beacon nobody can
      hear. Ranging gives it away - every measurement comes back rssi 0, accuracy -1.

      So being granted "always" is not enough, and precise access is asked for outright. The prompt
      needs NSLocationTemporaryUsageDescriptionDictionary with this key in the host app's Info.plist;
      without the entry iOS ignores the request, which is why the outcome is logged either way.
    */
    public func ensureFullAccuracy(completion: @escaping (Bool) -> Void) {
        guard #available(iOS 14.0, *) else {
            completion(true)
            return
        }

        if locationManager.accuracyAuthorization == .fullAccuracy {
            completion(true)
            return
        }

        locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "BeaconMonitoring") { [weak self] error in
            let granted = self?.locationManager.accuracyAuthorization == .fullAccuracy
            if let error = error {
                NSLog("CapacitorIbeacon: precise location request failed: %@", error.localizedDescription)
            }
            NSLog("CapacitorIbeacon: precise location %@ - beacon monitoring %@",
                  granted ? "granted" : "NOT granted",
                  granted ? "can report crossings" : "will stay silent")
            completion(granted)
        }
    }

    public func hasFullAccuracy() -> Bool {
        if #available(iOS 14.0, *) {
            return locationManager.accuracyAuthorization == .fullAccuracy
        }
        return true
    }

    private func settleAuthorization() {
        let callbacks = authorizationCallbacks
        authorizationCallbacks.removeAll()
        authorizationTarget = nil

        // Reduced accuracy makes an "always" grant useless for beacons, so the answer is not final
        // until precise access has been asked for as well.
        ensureFullAccuracy { [weak self] _ in
            let status = self?.getAuthorizationStatus() ?? "unknown"
            callbacks.forEach { $0(status) }
        }
    }

    private func currentAuthorizationStatus() -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return locationManager.authorizationStatus
        }
        return CLLocationManager.authorizationStatus()
    }

    public func getAuthorizationStatus() -> String {
        switch currentAuthorizationStatus() {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            // Not "always" in any useful sense for beacons if the location is coarse.
            return hasFullAccuracy() ? "authorized_always" : "authorized_reduced_accuracy"
        case .authorizedWhenInUse:
            return "authorized_when_in_use"
        @unknown default:
            return "unknown"
        }
    }

    public func isBluetoothEnabled(completion: @escaping (Bool) -> Void) {
        withReadyPeripheralManager { manager in
            completion(manager.state == .poweredOn)
        }
    }

    public func isRangingAvailable() -> Bool {
        return CLLocationManager.isRangingAvailable()
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
        if diagnosticRangingEnabled {
            // Throttled: this fires about once a second per region while the app is in the
            // foreground. An empty list is the interesting case - it means the OS is scanning and
            // hearing nothing, as opposed to not scanning at all.
            let now = Date()
            if now.timeIntervalSince(lastRangeLog[region.identifier] ?? .distantPast) >= rangeLogInterval {
                lastRangeLog[region.identifier] = now
                if beacons.isEmpty {
                    NSLog("CapacitorIbeacon: ranged %@ - nothing heard", region.identifier)
                } else {
                    let detail = beacons.map { "rssi \($0.rssi) accuracy \(String(format: "%.1f", $0.accuracy))" }
                        .joined(separator: "; ")
                    NSLog("CapacitorIbeacon: ranged %@ - %d heard: %@", region.identifier, beacons.count, detail)
                }
            }
        }

        var beaconsArray: [[String: Any]] = []

        for beacon in beacons {
            var proximityString = "unknown"
            switch beacon.proximity {
            case .immediate:
                proximityString = "immediate"
            case .near:
                proximityString = "near"
            case .far:
                proximityString = "far"
            case .unknown:
                proximityString = "unknown"
            @unknown default:
                proximityString = "unknown"
            }

            beaconsArray.append([
                "uuid": beacon.uuid.uuidString,
                "major": beacon.major.intValue,
                "minor": beacon.minor.intValue,
                "rssi": beacon.rssi,
                "proximity": proximityString,
                "accuracy": beacon.accuracy
            ])
        }

        plugin?.notifyListeners("didRangeBeacons", data: [
            "region": [
                "identifier": region.identifier,
                "uuid": region.uuid.uuidString
            ],
            "beacons": beaconsArray
        ])
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        if let beaconRegion = region as? CLBeaconRegion {
            report(beaconRegion, state: .inside, fromCrossing: true)
        }
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        if let beaconRegion = region as? CLBeaconRegion {
            report(beaconRegion, state: .outside, fromCrossing: true)
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = currentAuthorizationStatus()
        guard !authorizationCallbacks.isEmpty, status != .notDetermined else { return }

        // Waiting on "always" but only granted when-in-use so far: iOS may still upgrade it, so let
        // the timeout decide rather than reporting a half-answer as the final one.
        if authorizationTarget == .authorizedAlways, status == .authorizedWhenInUse {
            return
        }

        settleAuthorization()
    }

    // Answers requestState(), and iOS also volunteers this on its own - notifyEntryStateOnDisplay
    // makes every screen-on while inside a region deliver one.
    public func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let beaconRegion = region as? CLBeaconRegion else { return }

        switch state {
        case .inside, .outside:
            report(beaconRegion, state: state, fromCrossing: false)
        case .unknown:
            // Nothing determined yet - typically no beacon has been scanned for. Left unrecorded so
            // that the retry in startMonitoringForRegion() still asks again.
            break
        @unknown default:
            break
        }
    }

    /*
      Enter and exit are transitions here, as they are on Android, because the same state arrives
      repeatedly on iOS: from requestState(), and from notifyEntryStateOnDisplay on every screen-on.
      Reporting each one would mean an enter event - and for this app a push notification - every
      time the user glanced at the phone next to a beacon.

      A determination is also not an arrival unless something was already known about the region. iOS
      volunteers one after a launch, and notifyEntryStateOnDisplay produces one whenever the screen
      comes on inside a region; with nothing remembered yet - a fresh process - reporting those would
      mean an enter on every relaunch, for a region entered long ago. The exception is the region just
      selected by the user, whose state was deliberately cleared and asked for in
      startMonitoringForRegion(), and which is seeded to .outside there before any answer arrives.

      Only an explicit didExitRegion counts as a departure. A determination of .outside is an
      instantaneous sample - a screen-on at a moment the beacon happened not to be heard - whereas
      Core Location delays a real exit deliberately to ride out exactly that. Turning those samples
      into exits would import the flapping that had to be suppressed on Android, so they update the
      remembered state and report the state, and nothing more. Android likewise reports an initial
      .outside without an exit event.
    */
    private func report(_ region: CLBeaconRegion, state: CLRegionState, fromCrossing: Bool) {
        let previous = monitoredRegionStates[region.identifier]
        monitoredRegionStates[region.identifier] = state
        guard previous != state else { return }

        let regionPayload: [String: Any] = [
            "identifier": region.identifier,
            "uuid": region.uuid.uuidString
        ]

        if state == .inside, fromCrossing || previous != nil {
            plugin?.notifyListeners("didEnterRegion", data: ["region": regionPayload])
            broadcast("didEnterRegion", region)
        } else if state == .outside, fromCrossing {
            plugin?.notifyListeners("didExitRegion", data: ["region": regionPayload])
            broadcast("didExitRegion", region)
        }

        plugin?.notifyListeners("didDetermineStateForRegion", data: [
            "region": regionPayload,
            "state": state == .inside ? "enter" : "exit"
        ])
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Logged unconditionally: this is how Core Location says it declined to monitor, and it was
        // previously only reported to a JS listener that may well not exist yet.
        NSLog("CapacitorIbeacon: monitoring FAILED for %@: %@",
              (region as? CLBeaconRegion)?.identifier ?? "unknown region", error.localizedDescription)

        if let beaconRegion = region as? CLBeaconRegion {
            plugin?.notifyListeners("monitoringDidFailForRegion", data: [
                "region": [
                    "identifier": beaconRegion.identifier,
                    "uuid": beaconRegion.uuid.uuidString
                ],
                "error": error.localizedDescription
            ])
        }
    }

    /*
      Region events also go out on NotificationCenter, so that native code in the host app can act on
      them without owning the CLLocationManager this class owns - the counterpart of adding a second
      MonitorNotifier to the application-wide BeaconManager on Android.

      Deliberately a plain string rather than a shared symbol: an observer needs no import, and the
      contract is just this name plus the userInfo keys below.
    */
    public static let regionEventNotification = Notification.Name("CapacitorIbeaconRegionEvent")

    private func broadcast(_ event: String, _ region: CLBeaconRegion) {
        NotificationCenter.default.post(
            name: CapacitorIbeacon.regionEventNotification,
            object: nil,
            userInfo: [
                "event": event,
                "identifier": region.identifier,
                "uuid": region.uuid.uuidString
            ]
        )
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard !peripheralManagerReadyCallbacks.isEmpty else {
            return
        }
        let callbacks = peripheralManagerReadyCallbacks
        peripheralManagerReadyCallbacks.removeAll()
        callbacks.forEach { $0(peripheral) }
    }
}
