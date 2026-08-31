import Foundation
import CoreLocation
import CoreBluetooth
import UIKit

/*
  Sendable by confinement rather than by construction.

  CLMonitor and CLServiceSession are async, so their events are read inside Tasks - which makes the
  compiler ask how this class can be touched from them. The answer is that it never is: every Task
  here awaits, snapshots what it needs into values, and hands those to DispatchQueue.main. All
  mutable state is therefore read and written on the main queue only, alongside the Core Location
  delegate callbacks and the plugin calls, which arrive there already.
*/
public class CapacitorIbeacon: NSObject, CLLocationManagerDelegate, CBPeripheralManagerDelegate, @unchecked Sendable {

    /*
      One instance per process, not one per bridge.

      Core Location keeps monitoring the app's conditions after the app is terminated, and relaunches
      it in the background to deliver a crossing - within moments, and long before a Capacitor bridge,
      its WebView and a remote frontend could be ready. Anything created with the bridge therefore
      does not exist when the event arrives, and the event is delivered nowhere and lost.

      So monitoring lives for as long as the process does, and the bridge attaches to it when there
      happens to be one - the counterpart of holding the scan state in statics on Android, where the
      Activity comes and goes while the foreground service keeps the scan alive. start() is called
      from the host app's AppDelegate, before any bridge exists.
    */
    public static let shared = CapacitorIbeacon()

    // MARK: - Monitoring

    /*
      Monitoring is CLMonitor's, not CLLocationManager's.

      CLLocationManager's startMonitoring(for:)/stopMonitoring(for:)/requestState(for:) and
      CLBeaconRegion itself are all marked deprecated toward CLMonitor and CLBeaconIdentityCondition.
      They carry API_TO_BE_DEPRECATED, which names no version and so emits no warning - the entire
      monitoring core was quietly on the way out while the compiler said nothing.

      The move is not only about staying current. Conditions are keyed by identifier, which is what
      this plugin's own API is keyed by; their state is persisted by the framework across termination;
      and on iOS 18 each event explains its own silence (see describeDiagnostics). All three were
      hand-rolled here before, and the last one could not be done at all.
    */
    private static let monitorName = "CapacitorIbeaconMonitor"
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    // Mirrors the conditions handed to CLMonitor, so the identifier-keyed API can answer questions
    // without awaiting the monitor. CLMonitor remains the authority; this is a cache.
    var conditions: [String: CLMonitor.BeaconIdentityCondition] = [:]
    /*
      Whether an enter has been announced for an identifier, so nothing is announced twice.

      CLMonitor delivers state, and the same state can arrive more than once - a repeated .satisfied
      must not become a second enter, which for a consuming app means a second push notification. The
      framework's own record(for:) is not used for this: it is updated around event delivery, so
      comparing an event against it invites the off-by-one that let one event validate the next.
    */
    var announcedInside: [String: Bool] = [:]

    // MARK: - Authorization state

    var locationManager: CLLocationManager!
    private var peripheralManager: CBPeripheralManager!
    weak var plugin: CapacitorIbeaconPlugin?
    private var peripheralManagerReadyCallbacks: [(CBPeripheralManager) -> Void] = []
    // The first CBPeripheralManager of an app's life also waits for the user to answer the Bluetooth
    // prompt, which takes longer than a few seconds. Too short a timeout reports the .unknown state
    // as "Bluetooth is off" while it is merely undecided.
    private let peripheralManagerStateTimeout: TimeInterval = 30.0

    private var authorizationCallbacks: [(String) -> Void] = []
    private var authorizationTarget: CLAuthorizationStatus?
    private let authorizationTimeout: TimeInterval = 60.0

    /*
      On iOS 18 an "always" grant is not enough on its own - a session must be held to use it.

      From CLServiceSession.h: an app with Always authorization "which is not holding such a
      CLServiceSession will not be able to receive CLLocationUpdate.liveUpdates() or
      CLMonitor.events() when it is not in-use". So without this object, background monitoring - the
      whole point of the plugin - silently delivers nothing.

      It must be taken while in-use, or immediately at launch if one was held when the process last
      ran; taken any other way it reports insufficientlyInUse and does nothing. Hence the durable
      flag: it records that always-operation was configured in some earlier run, which is what makes
      re-taking it during a background relaunch legitimate.
    */
    private var serviceSession: CLServiceSession?
    private var sessionDiagnosticsTask: Task<Void, Never>?
    private static let alwaysConfiguredKey = "CapacitorIbeacon.alwaysOperationConfigured"

    // MARK: - Ranging state

    /*
      Ranging stays on CLLocationManager, because there is nowhere else for it to go.

      startRangingBeacons(in:) is hard-deprecated in favour of startRangingBeacons(satisfying:), and
      that takes a CLBeaconIdentityConstraint - a type itself marked deprecated toward
      CLBeaconIdentityCondition, which has no ranging API at all. CLMonitor does not range. So the
      constraint form is simultaneously the current one and the last one, and it emits no warning at
      any deployment target.

      The exact constraint used to start is kept, never rebuilt. stopRangingBeacons(satisfying:)
      matches on the constraint, and a constraint rebuilt from a different subset of uuid/major/minor
      is a different constraint that stops nothing - ranging would then run until the process died.
    */
    var rangingConstraints: [String: CLBeaconIdentityConstraint] = [:]
    // Ranging asked for through the plugin API, and ranging this class turned on by itself. Kept
    // apart so neither can cancel the other: an exit must not stop ranging a caller asked for, and
    // a caller's stop must not cancel ranging that a region occupancy still justifies.
    var explicitRanging: Set<String> = []
    var automaticRanging: Set<String> = []
    // Constraints currently ranging at the OS level, keyed by their canonical form, holding the very
    // object passed to startRangingBeacons so that stop can pass the same one.
    var activeRanging: [String: CLBeaconIdentityConstraint] = [:]

    /*
      Background ranging does not exist on iOS, so this does not pretend to provide it.

      Ranging only produces measurements while the process is unsuspended, and Apple's position is
      that ranging was never meant to work in the background at all unless some other capability is
      keeping the app alive. Even that no longer holds: on iOS 18 the ranging callback keeps firing
      with empty arrays once the display goes off, so the scan - not the process - is what stops.

      What is available is the few seconds of runtime that a monitoring event itself buys. So a
      crossing delivered to a backgrounded process ranges for that window and stops: it captures the
      proximity of the beacon at the moment of the crossing, which is the most useful instant of the
      whole visit, and costs nothing that was not already running. Sustained ranging happens only in
      the foreground, where it genuinely works.
    */
    let backgroundBurstDuration: TimeInterval = 10.0
    var burstTimers: [String: Timer] = [:]

    /*
      Restates what CLMonitor believes it is monitoring, and under what permissions.

      Everything about monitoring is otherwise invisible until it speaks: a condition silently
      dropped, an authorization downgraded while the app ran, and a condition being watched normally
      all look identical from outside. Stated on a timer so the silence can be attributed.
    */
    private var monitoringAuditTimer: Timer?
    private let monitoringAuditInterval: TimeInterval = 60
    private var applicationObservers: [NSObjectProtocol] = []
    private var protectedDataObserver: NSObjectProtocol?

    override public init() {
        super.init()
        locationManager = CLLocationManager()
        locationManager.delegate = self
        // peripheralManager intentionally not constructed here - see withReadyPeripheralManager().
    }

    // MARK: - Lifecycle

    /*
      Called from the host app's AppDelegate on every launch, background relaunches included.

      Three things have to happen before Core Location delivers anything, and all of them are why
      this cannot wait for a bridge:

      - The service session is re-taken. Without it, an always-authorized app receives no monitor
      events while not in-use.
      - The monitor is opened by name and its events are drained. CLMonitor.h is explicit that
      CoreLocation "will stop monitoring conditions if an event is pending for them, but no
      CLMonitor has been configured to receive it" - so failing to open it here does not merely
      miss one event, it ends monitoring altogether.
      - Conditions are adopted from the monitor's own persisted records, so monitoring re-asserts
      without the frontend having to ask, and keeps working even if the frontend never loads.
    */
    public func start(diagnosticLogFile: Bool = false) {
        // Before the first line below, so that the launch state - the authorization and accuracy that
        // decide whether monitoring can report anything at all - is in the file rather than only in a
        // console nobody was attached to. See CapacitorIbeaconDiagnosticLog.
        CapacitorIbeaconDiagnosticLog.isEnabled = diagnosticLogFile

        /*
          iOS declines to monitor beacons on reduced accuracy. On iOS 18 a monitor event says so
          itself through accuracyLimited, but the launch state is worth stating outright, since it is
          a Settings toggle rather than anything the code can fix.
        */
        beaconLog("CapacitorIbeacon: authorization %@, accuracy %@, bluetooth-dependent monitoring",
                  getAuthorizationStatus(), hasFullAccuracy() ? "full" : "REDUCED")

        observeApplicationState()
        retakeServiceSessionIfConfigured()
        openMonitor()

        monitoringAuditTimer?.invalidate()
        monitoringAuditTimer = Timer.scheduledTimer(withTimeInterval: monitoringAuditInterval,
                                                    repeats: true) { [weak self] _ in
            self?.auditMonitoring("periodic")
        }
    }

    /*
      Conditions live in a file in the app's data container, and CLMonitor.h says to wait for
      protected data before opening one. A device that reboots and hears a beacon before the user has
      unlocked it once would otherwise open a monitor that cannot read its own conditions - which
      arrives as persistenceUnavailable, if it arrives at all.
    */
    private func openMonitor() {
        guard monitorTask == nil else { return }

        if !UIApplication.shared.isProtectedDataAvailable {
            beaconLog("CapacitorIbeacon: protected data unavailable, deferring monitor until first unlock")
            guard protectedDataObserver == nil else { return }
            protectedDataObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil, queue: .main) { [weak self] _ in
                beaconLog("CapacitorIbeacon: protected data available, opening monitor")
                self?.openMonitor()
            }
            return
        }

        monitorTask = Task { [weak self] in
            let monitor = await CLMonitor(CapacitorIbeacon.monitorName)

            // Adopted before the drain begins: an event for a condition this process has not yet
            // heard of would otherwise be judged against nothing and announced as news.
            var adopted: [AdoptedCondition] = []
            for identifier in await monitor.identifiers {
                guard let record = await monitor.record(for: identifier),
                      let condition = record.condition as? CLMonitor.BeaconIdentityCondition else { continue }
                adopted.append(AdoptedCondition(identifier: identifier,
                                                condition: condition,
                                                inside: record.lastEvent.state == .satisfied))
            }

            DispatchQueue.main.async {
                self?.monitor = monitor
                self?.adopt(adopted)
            }

            /*
              Drained for the life of the process. The sequence is the only delivery mechanism there
              is, and an event that arrives while nobody is iterating is an event that stops
              monitoring - so this loop is not allowed to end quietly.
            */
            do {
                for try await event in await monitor.events {
                    let snapshot = MonitorEventSnapshot(identifier: event.identifier,
                                                        state: event.state,
                                                        diagnostics: CapacitorIbeacon.describeDiagnostics(event))
                    DispatchQueue.main.async { self?.handle(snapshot) }
                }
                beaconLog("CapacitorIbeacon: monitor event stream ENDED - monitoring is no longer being received")
            } catch {
                beaconLog("CapacitorIbeacon: monitor event stream FAILED: %@", error.localizedDescription)
            }
        }
    }

    private func adopt(_ adopted: [AdoptedCondition]) {
        for entry in adopted {
            let identifier = entry.identifier
            conditions[identifier] = entry.condition
            rangingConstraints[identifier] = CapacitorIbeacon.constraint(from: entry.condition)
            /*
              The persisted state is adopted as already announced, which is what keeps a relaunch
              quiet. Before CLMonitor this state died with the process, so a region entered long ago
              had to be left deliberately unknown to stop it being re-announced on every launch;
              now the framework remembers, and a repeat of a state already reported is recognisably
              a repeat rather than merely unjudgeable.
            */
            announcedInside[identifier] = entry.inside
        }

        let names = adopted.map { "\($0.identifier)\($0.inside ? " (inside)" : "")" }.sorted()

        // Also the marker for "is this build running the process-scoped monitoring?", which is
        // otherwise unanswerable from outside: Swift method names are mangled away in a release
        // binary, so only a string literal like this one survives to be grepped for in an .ipa.
        beaconLog("CapacitorIbeacon: monitoring started for the process, adopted %d condition(s): %@",
                  adopted.count, names.isEmpty ? "(none)" : names.joined(separator: ", "))

        // A region adopted as occupied deserves ranging as much as one just entered, and after a
        // foreground relaunch this is the only place that occupancy is learned.
        refreshAutomaticRanging()
        auditMonitoring("launch")
    }

    // The bridge that is currently alive, or nil while none is - JS events are routed through it and
    // dropped when there is none, while the native broadcast below happens either way.
    public func setPlugin(_ plugin: CapacitorIbeaconPlugin?) {
        self.plugin = plugin
    }

    public func isCurrentPlugin(_ candidate: CapacitorIbeaconPlugin) -> Bool {
        return plugin === candidate
    }

    // MARK: - Monitor events

    // Named rather than a tuple: three values travel together from the monitor's records into
    // adopt(), and "the Bool" is not a readable way to say whether a region is occupied.
    private struct AdoptedCondition {
        let identifier: String
        let condition: CLMonitor.BeaconIdentityCondition
        let inside: Bool
    }

    private struct MonitorEventSnapshot {
        let identifier: String
        let state: CLMonitor.Event.State
        let diagnostics: [String]
    }

    /*
      Every reason iOS 18 gives for an event, in the order that matters for reading a log.

      These are the whole argument for the migration. Each one names a way monitoring goes silent
      that previously had to be guessed at from an audit timer and a log line - and, critically, each
      one distinguishes "the beacon is not here" from "I cannot tell you whether the beacon is here".
    */
    private static func describeDiagnostics(_ event: CLMonitor.Event) -> [String] {
        var reasons: [String] = []
        if event.accuracyLimited { reasons.append("accuracy limited (Precise Location is off)") }
        if event.authorizationDenied { reasons.append("authorization denied") }
        if event.authorizationDeniedGlobally { reasons.append("Location Services disabled system-wide") }
        if event.authorizationRestricted { reasons.append("authorization restricted") }
        if event.insufficientlyInUse { reasons.append("app not sufficiently in-use") }
        if event.serviceSessionRequired { reasons.append("no service session held") }
        if event.persistenceUnavailable { reasons.append("condition persistence unavailable") }
        if event.conditionUnsupported { reasons.append("condition unsupported") }
        if event.conditionLimitExceeded { reasons.append("condition limit exceeded") }
        if event.authorizationRequestInProgress { reasons.append("authorization request in progress") }
        return reasons
    }

    /*
      Turns a monitor event into an enter, an exit, or deliberate silence.

      The rule is asymmetric, and the asymmetry is the point. A satisfied event is positive evidence
      that the beacon is present, and is announced whatever else the event says about the state of
      the app's permissions. An unsatisfied event is not evidence of absence: it is also what iOS
      sends when it has been prevented from telling - accuracy limited, authorization revoked,
      condition unsupported, no session held. Announcing those as exits would mean that turning off
      Precise Location, or a session lapsing, reads to the consuming app exactly like the user
      walking out of the building.

      Before iOS 18 this distinction was not available at all, which is why the old code refused to
      trust anything except a crossing and let a stay run forever rather than risk a false exit.
    */
    private func handle(_ event: MonitorEventSnapshot) {
        let identifier = event.identifier
        let reasons = event.diagnostics.joined(separator: ", ")
        let wasInside = announcedInside[identifier] ?? false

        let stateName: String
        switch event.state {
        case .satisfied: stateName = "satisfied"
        case .unsatisfied: stateName = "unsatisfied"
        case .unknown: stateName = "unknown"
        case .unmonitored: stateName = "unmonitored"
        @unknown default: stateName = "?"
        }

        beaconLog("CapacitorIbeacon: << monitor %@ %@%@, app %@ (announced %@)",
                  identifier,
                  stateName,
                  event.diagnostics.isEmpty ? "" : " [\(reasons)]",
                  CapacitorIbeacon.applicationStateName(),
                  wasInside ? "inside" : "outside")

        // A blocked event is a monitoring failure with a stated cause, which is exactly what this
        // event has always meant to a consuming app - it just never had a reason to carry.
        if !event.diagnostics.isEmpty {
            plugin?.notifyListeners("monitoringDidFailForRegion", data: [
                "region": regionPayload(identifier),
                "error": reasons
            ])
        }

        switch event.state {
        case .satisfied:
            guard !wasInside else {
                beaconLog("CapacitorIbeacon: %@ enter suppressed, already announced inside", identifier)
                return
            }
            announcedInside[identifier] = true
            announce("didEnterRegion", identifier: identifier, state: "enter")
            beginRanging(for: identifier)

        case .unsatisfied:
            /*
              Only a clean unsatisfied ends a stay. With any diagnostic set, the state is the
              framework reporting that it cannot see, and the stay is left standing: a region wrongly
              held open recovers on the next real event, while a wrongly announced exit is a
              notification the user has already read.
            */
            guard event.diagnostics.isEmpty else {
                beaconLog("CapacitorIbeacon: %@ exit SUPPRESSED, unsatisfied only because: %@", identifier, reasons)
                return
            }
            guard wasInside else {
                beaconLog("CapacitorIbeacon: %@ exit suppressed, no announced stay to end", identifier)
                return
            }
            announcedInside[identifier] = false
            announce("didExitRegion", identifier: identifier, state: "exit")
            endRanging(for: identifier)

        case .unknown:
            // Nothing determined yet - typically nothing has been scanned for. Left alone so that a
            // later definite answer is still news.
            break

        case .unmonitored:
            // The framework saying it has stopped watching this condition. Nothing here can restore
            // it, but silence from now on has a cause, and this is the only place it is stated.
            beaconLog("CapacitorIbeacon: %@ is NO LONGER MONITORED - no further events will arrive for it",
                      identifier)
            endRanging(for: identifier)

        @unknown default:
            break
        }
    }

    // The constraint is the fallback, not an afterthought: an identifier can be ranged without ever
    // being monitored, and the payload has always carried a uuid.
    func regionPayload(_ identifier: String) -> [String: Any] {
        var payload: [String: Any] = ["identifier": identifier]
        if let uuid = conditions[identifier]?.uuid ?? rangingConstraints[identifier]?.uuid {
            payload["uuid"] = uuid.uuidString
        }
        return payload
    }

    private func announce(_ event: String, identifier: String, state: String) {
        beaconLog("CapacitorIbeacon: %@ %@ announced", identifier, state == "enter" ? "ENTER" : "EXIT")

        let payload = regionPayload(identifier)
        plugin?.notifyListeners(event, data: ["region": payload])
        plugin?.notifyListeners("didDetermineStateForRegion", data: [
            "region": payload,
            "state": state
        ])
        broadcast(event, identifier: identifier)
    }

    // MARK: - Monitoring API

    public func startMonitoringForRegion(identifier: String, uuid: String, major: Int?, minor: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        let condition = CapacitorIbeacon.condition(beaconUUID, major, minor)
        let constraint = CapacitorIbeacon.constraint(beaconUUID, major, minor)

        /*
          An identifier repointed at a different beacon has to let go of the old one here.

          Ranging is reconciled from the constraints these identifiers currently name, so replacing
          this one silently removes the old constraint from everything that could ask for it - while
          the OS is still ranging it, and activeRanging still holds it under its own key. Nothing
          would notice until some unrelated call reconciled again, and until then the plugin ranges a
          beacon no caller has named since.

          The occupancy goes with it. automaticRanging exists because a region was entered, and the
          region that was entered was the old beacon's - the Task below reaches the same conclusion
          about announcedInside when it finds the condition changed.
        */
        let previous = rangingConstraints[identifier]
        conditions[identifier] = condition
        rangingConstraints[identifier] = constraint

        // Reconciled after the assignment, never before: the reconcile decides what should be ranging
        // from the constraints these identifiers now name, so it has to be reading the new one.
        if let previous = previous,
           CapacitorIbeacon.key(for: previous) != CapacitorIbeacon.key(for: constraint) {
            beaconLog("CapacitorIbeacon: startMonitoring %@ - now names %@, was %@",
                      identifier, CapacitorIbeacon.key(for: constraint), CapacitorIbeacon.key(for: previous))
            automaticRanging.remove(identifier)
            burstTimers[identifier]?.invalidate()
            burstTimers.removeValue(forKey: identifier)
            reconcileRanging()
        }

        Task { [weak self] in
            guard let monitor = await self?.awaitMonitor() else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "CapacitorIbeacon", code: -3,
                                                userInfo: [NSLocalizedDescriptionKey: "Monitoring is unavailable"])))
                }
                return
            }

            let existing = await monitor.record(for: identifier)?.condition as? CLMonitor.BeaconIdentityCondition
            let unchanged = existing.map { CapacitorIbeacon.same($0, condition) } ?? false

            /*
              Re-registering an unchanged condition is a no-op, and deliberately so.

              Conditions persist across launches while a frontend re-asserts its monitoring on every
              app start, so most calls here describe something already being watched. Adding it again
              would reset the state CLMonitor has been tracking, discarding a stay in progress - which
              is how this once presented as "exits never fire": the reset made every arrival a fresh
              entry, so enters kept working while the pending exit was destroyed each time.
            */
            if unchanged {
                beaconLog("CapacitorIbeacon: startMonitoring %@ - already monitored, state left alone", identifier)
            } else {
                if existing != nil {
                    // Same name, different beacon: a different condition wearing a used identifier
                    // has to replace what is being watched rather than sit beside it.
                    beaconLog("CapacitorIbeacon: startMonitoring %@ - replacing a condition of the same identifier",
                              identifier)
                    await monitor.remove(identifier)
                }

                /*
                  This process's record of the state is enqueued before the condition exists, and
                  that order is the whole point.

                  Both this write and handle() run on the main queue, so the queue orders them by
                  when they were enqueued rather than by where they sit in this function. Enqueued
                  after the add, a .satisfied arriving in between is announced first and then
                  overwritten here: the region then reads as outside while the user is standing in
                  it, so the next repeat of that state is announced as a second enter, and the real
                  exit is dropped for having no stay to end. Enqueued before the add, no event for
                  this identifier can exist yet, so nothing can get in front of it.

                  After the remove above rather than before it, so that a removal which ends a stay
                  is still judged against the state that stay was announced with.
                */
                DispatchQueue.main.async { self?.announcedInside[identifier] = false }

                /*
                  Seeded as unsatisfied, so that a region the user is already standing in reports
                  itself. Monitoring speaks on change, and assuming the opposite of what is likely
                  true is what turns the first observation into an event - the same reason the old
                  code seeded a state and then asked for it outright, minus the asking.
                */
                await monitor.add(condition, identifier: identifier, assuming: .unsatisfied)
                beaconLog("CapacitorIbeacon: startMonitoring %@ - NEW, assumed outside", identifier)
            }

            DispatchQueue.main.async {
                completion(.success(()))
                self?.auditMonitoring("after registering \(identifier)")
            }
        }
    }

    /*
      Retires the identifier altogether, ranging included.

      Ranging is reconciled after the constraint is forgotten, not before: the reconcile decides what
      should be ranging from the identifiers that remain, so dropping the constraint first is what
      makes the OS-level ranging disappear from the desired set and be stopped. Done the other way
      round, an identifier that was also being ranged explicitly kept ranging with nothing left able
      to name it, until some unrelated call reconciled again.
    */
    public func stopMonitoringForRegion(identifier: String, uuid: String) {
        explicitRanging.remove(identifier)
        automaticRanging.remove(identifier)
        burstTimers[identifier]?.invalidate()
        burstTimers.removeValue(forKey: identifier)
        conditions.removeValue(forKey: identifier)
        announcedInside.removeValue(forKey: identifier)
        rangingConstraints.removeValue(forKey: identifier)
        reconcileRanging()

        Task { [weak self] in
            guard let monitor = await self?.awaitMonitor() else { return }
            await monitor.remove(identifier)
            beaconLog("CapacitorIbeacon: stopMonitoring %@", identifier)
        }
    }

    // The monitor is opened asynchronously and every API call may land before it exists. Waiting is
    // correct rather than failing: the call was made against a plugin that is starting up, not
    // against one that has no monitoring.
    private func awaitMonitor() async -> CLMonitor? {
        // Read on the main queue like every other piece of state here, rather than touched directly
        // from this Task - see the note on @unchecked Sendable above.
        for attempt in 0...50 {
            if let monitor = await currentMonitor() { return monitor }
            if attempt < 50 { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        beaconLog("CapacitorIbeacon: monitor still unavailable after waiting - is start() called from the AppDelegate?")
        return nil
    }

    private func currentMonitor() async -> CLMonitor? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: self.monitor) }
        }
    }

    // MARK: - Advertising

    public func startAdvertising(uuid: String, major: Int, minor: Int, identifier: String, measuredPower: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        // The one remaining use of CLBeaconRegion: peripheralData(withMeasuredPower:) builds the
        // advertisement payload, and nothing in the condition APIs replaces it.
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
        // Not withReadyPeripheralManager(): stopping something that was never started shouldn't
        // newly construct (and trigger a permission prompt for) a manager that doesn't exist yet.
        peripheralManager?.stopAdvertising()
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

    // MARK: - Authorization

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

    /*
      Asking for "always" is taking the session, not calling requestAlwaysAuthorization().

      A CLServiceSession with an always requirement makes Location Services seek that authorization,
      and holding it is separately mandatory for receiving monitor events while not in-use - so the
      request and the thing that makes the grant usable are the same object.

      What it is not is an answer. The session is created while the status is still undecided, which
      is precisely what makes iOS ask - so always-operation cannot be marked as configured here
      without claiming a grant the user is still free to refuse. It is marked when the grant arrives
      instead, in locationManagerDidChangeAuthorization.

      When-in-use is still requested first if nothing has been decided yet, because iOS escalates to
      always from an existing grant rather than straight from undecided.
    */
    public func requestAlwaysAuthorization(completion: @escaping (String) -> Void) {
        requestAuthorization(target: .authorizedAlways, completion: completion) {
            if self.currentAuthorizationStatus() == .notDetermined {
                self.locationManager.requestWhenInUseAuthorization()
            }
            self.takeServiceSession(recordAsConfigured: false)
        }
    }

    private func requestAuthorization(
        target: CLAuthorizationStatus,
        completion: @escaping (String) -> Void,
        request: @escaping () -> Void
    ) {
        let current = currentAuthorizationStatus()

        /*
          Answered already, so nothing is asked and the completion is settled from what is known.

          Two ways to be answered. The grant covers the request, which is the ordinary case of a
          frontend re-asserting its permissions on every launch. Or the request is refused outright:
          iOS shows no prompt to an app that is denied or restricted, and reports no authorization
          change either, so waiting for the delegate means waiting out the whole timeout and then
          reporting the very status that was readable here from the start - a minute of a promise
          that never resolves, for a question that was settled before it was asked.
        */
        let refused = current == .denied || current == .restricted
        let covered = current != .notDetermined && (current == target || target == .authorizedWhenInUse)

        if refused || covered {
            /*
              Only a grant in hand justifies a session. Taking one under a refusal earns nothing but
              authorizationDenied diagnostics, and recording it as configured would be worse: that
              flag is the evidence retakeServiceSessionIfConfigured() relies on to take a session
              during a background relaunch, and it is meant to say a matching session was
              legitimately held in an earlier run. A refusal never held one.

              Recorded here rather than left to the delegate because nothing is changing, so no
              delegate callback is coming.
            */
            if current == .authorizedAlways, target == .authorizedAlways {
                takeServiceSession(recordAsConfigured: true)
            }
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
      Re-taken at launch, and only if it was configured before.

      CLServiceSession.h allows a session to be created while in-use, or "immediately when launched
      in the background if a matching session was held when previously running" - and Apple's
      guidance is blunter still about the when-in-use equivalent: such a session "cannot start in the
      background". So the durable flag is not a convenience, it is the thing that makes this legal:
      without evidence that always-operation was configured in an earlier run, taking a session here
      would only earn insufficientlyInUse.
    */
    private func retakeServiceSessionIfConfigured() {
        guard UserDefaults.standard.bool(forKey: CapacitorIbeacon.alwaysConfiguredKey) else {
            beaconLog("CapacitorIbeacon: no always-operation on record, no service session taken")
            return
        }
        takeServiceSession(recordAsConfigured: false)
    }

    private func takeServiceSession(recordAsConfigured: Bool) {
        if recordAsConfigured {
            UserDefaults.standard.set(true, forKey: CapacitorIbeacon.alwaysConfiguredKey)
        }

        guard serviceSession == nil else { return }

        let session = CLServiceSession(authorization: .always)
        serviceSession = session
        beaconLog("CapacitorIbeacon: service session taken (always)")

        /*
          The session reports its own suspension, and it is the only channel that does. A session
          that lapses stops monitor events without stopping anything else, so these lines are the
          difference between "the beacons went quiet" and "the session was suspended at 14:02".
        */
        sessionDiagnosticsTask?.cancel()
        sessionDiagnosticsTask = Task {
            do {
                for try await diagnostic in session.diagnostics {
                    var reasons: [String] = []
                    if diagnostic.authorizationDenied { reasons.append("authorization denied") }
                    if diagnostic.authorizationDeniedGlobally { reasons.append("Location Services disabled system-wide") }
                    if diagnostic.authorizationRestricted { reasons.append("authorization restricted") }
                    if diagnostic.insufficientlyInUse { reasons.append("app not sufficiently in-use") }
                    if diagnostic.alwaysAuthorizationDenied { reasons.append("always authorization denied") }
                    if diagnostic.fullAccuracyDenied { reasons.append("full accuracy denied") }
                    if diagnostic.serviceSessionRequired { reasons.append("service session required") }
                    if diagnostic.authorizationRequestInProgress { reasons.append("authorization request in progress") }

                    beaconLog("CapacitorIbeacon: service session %@",
                              reasons.isEmpty ? "active, no diagnostics" : "SUSPENDED: \(reasons.joined(separator: ", "))")
                }
            } catch {
                beaconLog("CapacitorIbeacon: service session diagnostics failed: %@", error.localizedDescription)
            }
        }
    }

    /*
      iOS will not monitor beacons on reduced accuracy, and before iOS 18 said so nowhere: no error,
      no failure callback, just permanent silence indistinguishable from a beacon nobody can hear.

      A monitor event now reports it itself, through accuracyLimited, which is what lets an
      unsatisfied state be recognised as "cannot tell" rather than "not here". This remains for the
      launch line and for getAuthorizationStatus(), which reports authorized_reduced_accuracy - only
      Settings > the app > Location > Precise Location settles it.
    */
    public func hasFullAccuracy() -> Bool {
        return locationManager.accuracyAuthorization == .fullAccuracy
    }

    private func settleAuthorization() {
        let callbacks = authorizationCallbacks
        authorizationCallbacks.removeAll()
        authorizationTarget = nil

        // Reduced accuracy makes an "always" grant useless for beacons, which is why the status this
        // reports distinguishes the two - see hasFullAccuracy().
        let status = getAuthorizationStatus()
        callbacks.forEach { $0(status) }
    }

    private func currentAuthorizationStatus() -> CLAuthorizationStatus {
        return locationManager.authorizationStatus
    }

    public func getAuthorizationStatus() -> String {
        let status = currentAuthorizationStatus()

        /*
          Reduced accuracy outranks which grant was given, because it settles the same question
          either way: iOS declines to monitor or range beacons without Precise Location, under a
          "when in use" grant exactly as under an "always" one. Reporting it for only one of the two
          hands the other a status this plugin documents as usable and then gives it silence - which
          is precisely the failure this value was added to name, arriving through the door left open.

          Which grant is underneath stops mattering once the accuracy is coarse, so it is deliberately
          not reported. Neither of them can see a beacon.
        */
        let granted = status == .authorizedAlways || status == .authorizedWhenInUse
        if granted, !hasFullAccuracy() {
            return "authorized_reduced_accuracy"
        }

        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorized_always"
        case .authorizedWhenInUse:
            return "authorized_when_in_use"
        @unknown default:
            return "unknown"
        }
    }

    /*
      Answers without constructing anything, because constructing is what asks the user.

      Merely instantiating a CBPeripheralManager raises the Bluetooth permission prompt - the reason
      withReadyPeripheralManager() defers it - so routing a getter through it put a dialog in front of
      the user for a capability none of this needs. Monitoring and ranging are CoreLocation's
      throughout; CoreBluetooth is here for startAdvertising() and nothing else. A status query that
      prompts is wrong whatever it goes on to answer.

      What can be told without asking:

      - A manager that already exists, because the app has advertised, knows and is simply read.
      - Refused or restricted authorization means Bluetooth is not this app's to use, whatever the
      radio happens to be doing.
      - Undetermined cannot be told at all. iOS offers no way to read the radio without first holding
      permission to use it, so this reports false rather than buying an answer with a prompt: "this
      app cannot currently use Bluetooth" is true either way, and it is the half that callers of a
      beacon plugin can act on.

      Callers gating beacon work on this should not: see getAuthorizationStatus(), which reports the
      permission monitoring actually depends on.
    */
    public func isBluetoothEnabled(completion: @escaping (Bool) -> Void) {
        if let manager = peripheralManager, manager.state != .unknown {
            completion(manager.state == .poweredOn)
            return
        }

        guard CBManager.authorization == .allowedAlways else {
            beaconLog("CapacitorIbeacon: isBluetoothEnabled - not authorized for this app, "
                      + "reporting false rather than prompting")
            completion(false)
            return
        }

        // Authorization is already held, so there is no prompt left to raise and the real state is
        // worth waiting for.
        withReadyPeripheralManager { manager in
            completion(manager.state == .poweredOn)
        }
    }

    public func isRangingAvailable() -> Bool {
        return CLLocationManager.isRangingAvailable()
    }

    // MARK: - Audit

    public func auditMonitoring(_ reason: String) {
        let ranging = activeRanging.keys.sorted()
        let expected = conditions.keys.sorted()

        beaconLog("CapacitorIbeacon: audit (%@) - authorization %@, accuracy %@, session %@, app %@, ranging %@",
                  reason,
                  getAuthorizationStatus(),
                  hasFullAccuracy() ? "full" : "REDUCED",
                  serviceSession == nil ? "NONE" : "held",
                  CapacitorIbeacon.applicationStateName(),
                  ranging.isEmpty ? "(none)" : ranging.joined(separator: ", "))

        guard let monitor = monitor else {
            beaconLog("CapacitorIbeacon: audit (%@) - NO MONITOR OPEN, nothing is being watched", reason)
            return
        }

        Task {
            var lines: [String] = []
            for identifier in await monitor.identifiers {
                guard let record = await monitor.record(for: identifier) else { continue }
                let state: String
                switch record.lastEvent.state {
                case .satisfied: state = "inside"
                case .unsatisfied: state = "outside"
                case .unknown: state = "unknown"
                case .unmonitored: state = "UNMONITORED"
                @unknown default: state = "?"
                }
                lines.append("\(identifier) \(state)")
            }

            beaconLog("CapacitorIbeacon: audit (%@) - CLMonitor watching %d: %@",
                      reason, lines.count, lines.isEmpty ? "(none)" : lines.sorted().joined(separator: ", "))

            // What this process thinks it registered, against what CLMonitor will admit to. A
            // condition in one and not the other is monitoring that will never report anything.
            let watched = await monitor.identifiers.sorted()
            if expected != watched {
                beaconLog("CapacitorIbeacon: audit (%@) - MISMATCH, this process expects %d: %@",
                          reason, expected.count, expected.isEmpty ? "(none)" : expected.joined(separator: ", "))
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = currentAuthorizationStatus()

        // Logged before the guard below, which returns early whenever no request is outstanding: a
        // downgrade the user makes in Settings while the app runs arrives here and nowhere else, and
        // it stops monitoring reporting anything without a single other symptom.
        auditMonitoring("authorization changed")

        /*
          Where always-operation is recorded as configured, for the same reason as the audit above:
          this is the one place the answer to the request lands, and it lands here whether it comes
          moments later from the prompt or hours later from Settings - the latter arriving with no
          callbacks outstanding at all, past the guard below.

          Conditioned on holding a session as well as on the grant, so that only an always-operation
          this process actually asked for is recorded. A user who grants "always" in Settings to an
          app that never wanted it leaves nothing behind for the next launch to act on.
        */
        if status == .authorizedAlways, serviceSession != nil {
            UserDefaults.standard.set(true, forKey: CapacitorIbeacon.alwaysConfiguredKey)
        }

        guard !authorizationCallbacks.isEmpty, status != .notDetermined else { return }

        // Waiting on "always" but only granted when-in-use so far: iOS may still upgrade it, so let
        // the timeout decide rather than reporting a half-answer as the final one.
        if authorizationTarget == .authorizedAlways, status == .authorizedWhenInUse {
            return
        }

        settleAuthorization()
    }

    // MARK: - Application state

    /*
      Foreground and background are load-bearing here, not incidental.

      Sustained ranging exists only in the foreground, and the burst exists only in the background,
      so the transition between them is what promotes one to the other - a region entered on the
      street keeps ranging when the user takes the phone out, and stops when they put it away.
    */
    private func observeApplicationState() {
        guard applicationObservers.isEmpty else { return }

        let center = NotificationCenter.default
        applicationObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.refreshAutomaticRanging()
            })
        applicationObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: .main) { [weak self] _ in
                self?.refreshAutomaticRanging()
            })
    }

    // Whether the UI was up when an event landed. A crossing delivered to a backgrounded or
    // freshly-relaunched process is the case that is hard to observe any other way, and the one
    // where events have been going missing.
    static func applicationStateName() -> String {
        var name = "unknown"
        let read = {
            switch UIApplication.shared.applicationState {
            case .active: name = "foreground"
            case .inactive: name = "inactive"
            case .background: name = "background"
            @unknown default: name = "unknown"
            }
        }
        if Thread.isMainThread {
            read()
        } else {
            DispatchQueue.main.sync(execute: read)
        }
        return name
    }

    static func isForeground() -> Bool {
        return applicationStateName() == "foreground"
    }

    // MARK: - Native broadcast

    /*
      Region events also go out on NotificationCenter, so that native code in the host app can act on
      them without owning the monitoring this class owns - the counterpart of adding a second
      MonitorNotifier to the application-wide BeaconManager on Android.

      Deliberately a plain string rather than a shared symbol: an observer needs no import, and the
      contract is just this name plus the userInfo keys below.
    */
    public static let regionEventNotification = Notification.Name("CapacitorIbeaconRegionEvent")

    private func broadcast(_ event: String, identifier: String) {
        var userInfo: [String: Any] = regionPayload(identifier)
        userInfo["event"] = event
        NotificationCenter.default.post(name: CapacitorIbeacon.regionEventNotification,
                                        object: nil, userInfo: userInfo)
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
