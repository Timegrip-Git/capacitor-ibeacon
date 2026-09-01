import Foundation
import CoreLocation

/*
  Ranging, split out from the monitoring it now hangs off.

  Monitoring moved to CLMonitor and ranging could not follow - there is no condition-based
  ranging API - so the two halves no longer share a mechanism, only a purpose. They are
  separated here to keep that visible: everything below is CLLocationManager's, and the
  identity helpers exist because a monitored condition and a ranged constraint describe the
  same beacon in two types that do not convert.
*/
extension CapacitorIbeacon {

    /*
      Ranging has two owners, and the reconciliation below is what keeps them from fighting.

      A caller starts and stops ranging through the plugin API, and this class starts and stops it by
      itself as regions are entered and left. Either alone is simple; together they cannot be a
      boolean, because a caller's stop must not cancel ranging an occupancy still justifies, and an
      exit must not cancel ranging a caller asked for.

      Both sets are therefore kept, the union is what should be ranging, and reconcileRanging() moves
      the OS to match. It is idempotent, which matters because both owners change under events that
      arrive in any order.
    */
    public func startRangingBeaconsInRegion(identifier: String, uuid: String, major: Int?, minor: Int?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let beaconUUID = UUID(uuidString: uuid) else {
            completion(.failure(NSError(domain: "CapacitorIbeacon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID"])))
            return
        }

        rangingConstraints[identifier] = CapacitorIbeacon.constraint(beaconUUID, major, minor)
        explicitRanging.insert(identifier)
        reconcileRanging()
        completion(.success(()))
    }

    public func stopRangingBeaconsInRegion(identifier: String, uuid: String) {
        explicitRanging.remove(identifier)
        reconcileRanging()
    }

    /*
      Started on entering a region that asked for it: for as long as the app is in the foreground, or
      for the length of the wake window if the crossing arrived in the background. See
      backgroundBurstDuration.

      Only for a region that asked. Ranging is a continuous Bluetooth scan and monitoring is not, so
      doing this for every monitored region billed every caller for a feature most of them never
      read - see automaticRangingRequested.
    */
    func beginRanging(for identifier: String) {
        guard rangingConstraints[identifier] != nil,
              automaticRangingRequested.contains(identifier) else { return }

        automaticRanging.insert(identifier)
        reconcileRanging()

        guard !CapacitorIbeacon.isForeground() else { return }

        burstTimers[identifier]?.invalidate()
        burstTimers[identifier] = Timer.scheduledTimer(withTimeInterval: backgroundBurstDuration,
                                                       repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.burstTimers.removeValue(forKey: identifier)
            // Only the burst ends here. Coming to the foreground while it ran promotes this to
            // sustained ranging, and that must not be cut short by a timer set in the background.
            guard !CapacitorIbeacon.isForeground() else { return }
            beaconLog("CapacitorIbeacon: %@ background ranging burst ended", identifier)
            self.automaticRanging.remove(identifier)
            self.reconcileRanging()
        }
        beaconLog("CapacitorIbeacon: %@ background ranging burst started (%.0fs)", identifier, backgroundBurstDuration)
    }

    func endRanging(for identifier: String) {
        burstTimers[identifier]?.invalidate()
        burstTimers.removeValue(forKey: identifier)
        automaticRanging.remove(identifier)
        reconcileRanging()
    }

    // Automatic ranging follows occupancy in the foreground and stops entirely in the background,
    // where it cannot produce measurements anyway. Explicit ranging is untouched: a caller that
    // asked for it gets whatever iOS is willing to deliver.
    func refreshAutomaticRanging() {
        if CapacitorIbeacon.isForeground() {
            let inside = announcedInside.filter { $0.value }.map { $0.key }
            automaticRanging = Set(inside.filter {
                rangingConstraints[$0] != nil && automaticRangingRequested.contains($0)
            })
        } else {
            burstTimers.values.forEach { $0.invalidate() }
            burstTimers.removeAll()
            automaticRanging.removeAll()
        }
        reconcileRanging()
    }

    func reconcileRanging() {
        var desired: [String: CLBeaconIdentityConstraint] = [:]
        for identifier in explicitRanging.union(automaticRanging) {
            guard let constraint = rangingConstraints[identifier] else { continue }
            desired[CapacitorIbeacon.key(for: constraint)] = constraint
        }

        for (key, constraint) in activeRanging where desired[key] == nil {
            // The stored object, not a rebuilt one - see rangingConstraints.
            locationManager.stopRangingBeacons(satisfying: constraint)
            activeRanging.removeValue(forKey: key)
            beaconLog("CapacitorIbeacon: ranging stopped for %@", key)
        }

        for (key, constraint) in desired where activeRanging[key] == nil {
            locationManager.startRangingBeacons(satisfying: constraint)
            activeRanging[key] = constraint
            beaconLog("CapacitorIbeacon: ranging started for %@", key)
        }
    }

    // MARK: - Ranging delegate

    public func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
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

        /*
          A constraint carries no identifier, so the identifier has to be recovered here.

          Ranging is keyed by beacon identity while this plugin's API is keyed by name, and the two
          are not one-to-one: the same uuid/major/minor can be registered under several identifiers,
          and iOS ranges it once. Each of them is told, because each of them asked - which is also
          why ranging is reconciled by constraint rather than by identifier.
        */
        let key = CapacitorIbeacon.key(for: constraint)
        let identifiers = rangingConstraints
            .filter { CapacitorIbeacon.key(for: $0.value) == key }
            .map { $0.key }
            .sorted()

        for identifier in identifiers {
            plugin?.notifyListeners("didRangeBeacons", data: [
                "region": regionPayload(identifier),
                "beacons": beaconsArray
            ])
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailRangingFor constraint: CLBeaconIdentityConstraint, error: Error) {
        beaconLog("CapacitorIbeacon: ranging FAILED for %@: %@",
                  CapacitorIbeacon.key(for: constraint), error.localizedDescription)
    }

    static func condition(_ uuid: UUID, _ major: Int?, _ minor: Int?) -> CLMonitor.BeaconIdentityCondition {
        if let major = major {
            if let minor = minor {
                return CLMonitor.BeaconIdentityCondition(uuid: uuid,
                                                         major: CLBeaconMajorValue(major),
                                                         minor: CLBeaconMinorValue(minor))
            }
            return CLMonitor.BeaconIdentityCondition(uuid: uuid, major: CLBeaconMajorValue(major))
        }
        return CLMonitor.BeaconIdentityCondition(uuid: uuid)
    }

    static func constraint(_ uuid: UUID, _ major: Int?, _ minor: Int?) -> CLBeaconIdentityConstraint {
        if let major = major {
            if let minor = minor {
                return CLBeaconIdentityConstraint(uuid: uuid,
                                                  major: CLBeaconMajorValue(major),
                                                  minor: CLBeaconMinorValue(minor))
            }
            return CLBeaconIdentityConstraint(uuid: uuid, major: CLBeaconMajorValue(major))
        }
        return CLBeaconIdentityConstraint(uuid: uuid)
    }

    // Ranging is asked for by condition but performed by constraint, so an adopted condition has to
    // be convertible into the constraint that ranges the same beacons.
    static func constraint(from condition: CLMonitor.BeaconIdentityCondition) -> CLBeaconIdentityConstraint {
        return constraint(condition.uuid,
                          condition.major.map { Int($0) },
                          condition.minor.map { Int($0) })
    }

    // A canonical name for a beacon identity, used to compare and to log. Wildcards are written
    // out rather than omitted, so uuid-with-major and uuid-alone can never collide.
    static func key(for constraint: CLBeaconIdentityConstraint) -> String {
        let major = constraint.major.map(String.init) ?? "*"
        let minor = constraint.minor.map(String.init) ?? "*"
        return "\(constraint.uuid.uuidString):\(major):\(minor)"
    }

    static func same(_ lhs: CLMonitor.BeaconIdentityCondition, _ rhs: CLMonitor.BeaconIdentityCondition) -> Bool {
        return lhs.uuid == rhs.uuid && lhs.major == rhs.major && lhs.minor == rhs.minor
    }
}
