import Foundation
import Capacitor
import CoreLocation

@objc(CapacitorIbeaconPlugin)
public class CapacitorIbeaconPlugin: CAPPlugin, CAPBridgedPlugin {
    private let pluginVersion: String = "8.1.34"
    public let identifier = "CapacitorIbeaconPlugin"
    public let jsName = "CapacitorIbeacon"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startMonitoringForRegion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopMonitoringForRegion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startRangingBeaconsInRegion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopRangingBeaconsInRegion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startAdvertising", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopAdvertising", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestWhenInUseAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestAlwaysAuthorization", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAuthorizationStatus", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isBluetoothEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "isRangingAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise)
    ]

    // The shared instance, not one of its own: monitoring outlives any bridge, see CapacitorIbeacon.
    private let implementation = CapacitorIbeacon.shared

    override public func load() {
        implementation.setPlugin(self)
    }

    // A bridge is torn down whenever the app is relaunched into the background, and the singleton
    // must not keep routing JS events at a dead one.
    deinit {
        if CapacitorIbeacon.shared.isCurrentPlugin(self) {
            CapacitorIbeacon.shared.setPlugin(nil)
        }
    }

    @objc func startMonitoringForRegion(_ call: CAPPluginCall) {
        guard let identifier = call.getString("identifier"),
              let uuid = call.getString("uuid") else {
            call.reject("Missing required parameters")
            return
        }

        implementation.startMonitoringForRegion(
            identifier: identifier,
            uuid: uuid,
            major: call.getInt("major"),
            minor: call.getInt("minor"),
            // Off unless asked for: ranging is a continuous Bluetooth scan, and most callers of a
            // monitoring API never read a didRangeBeacons event.
            automaticRanging: call.getBool("enableAutomaticRanging") ?? false
        ) { result in
            switch result {
            case .success:
                call.resolve()
            case .failure(let error):
                call.reject("Failed to start monitoring: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopMonitoringForRegion(_ call: CAPPluginCall) {
        guard let identifier = call.getString("identifier"),
              let uuid = call.getString("uuid") else {
            call.reject("Missing required parameters")
            return
        }

        implementation.stopMonitoringForRegion(identifier: identifier, uuid: uuid)
        call.resolve()
    }

    @objc func startRangingBeaconsInRegion(_ call: CAPPluginCall) {
        guard let identifier = call.getString("identifier"),
              let uuid = call.getString("uuid") else {
            call.reject("Missing required parameters")
            return
        }

        implementation.startRangingBeaconsInRegion(
            identifier: identifier,
            uuid: uuid,
            major: call.getInt("major"),
            minor: call.getInt("minor")
        ) { result in
            switch result {
            case .success:
                call.resolve()
            case .failure(let error):
                call.reject("Failed to start ranging: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopRangingBeaconsInRegion(_ call: CAPPluginCall) {
        guard let identifier = call.getString("identifier"),
              let uuid = call.getString("uuid") else {
            call.reject("Missing required parameters")
            return
        }

        implementation.stopRangingBeaconsInRegion(identifier: identifier, uuid: uuid)
        call.resolve()
    }

    @objc func startAdvertising(_ call: CAPPluginCall) {
        guard let uuid = call.getString("uuid"),
              let major = call.getInt("major"),
              let minor = call.getInt("minor"),
              let identifier = call.getString("identifier") else {
            call.reject("Missing required parameters")
            return
        }

        let measuredPower = call.getInt("measuredPower")

        implementation.startAdvertising(
            uuid: uuid,
            major: major,
            minor: minor,
            identifier: identifier,
            measuredPower: measuredPower
        ) { result in
            switch result {
            case .success:
                call.resolve()
            case .failure(let error):
                call.reject("Failed to start advertising: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopAdvertising(_ call: CAPPluginCall) {
        implementation.stopAdvertising()
        call.resolve()
    }

    @objc func requestWhenInUseAuthorization(_ call: CAPPluginCall) {
        implementation.requestWhenInUseAuthorization { status in
            call.resolve(["status": status])
        }
    }

    @objc func requestAlwaysAuthorization(_ call: CAPPluginCall) {
        implementation.requestAlwaysAuthorization { status in
            call.resolve(["status": status])
        }
    }

    @objc func getAuthorizationStatus(_ call: CAPPluginCall) {
        let status = implementation.getAuthorizationStatus()
        call.resolve(["status": status])
    }

    @objc func isBluetoothEnabled(_ call: CAPPluginCall) {
        implementation.isBluetoothEnabled { enabled in
            call.resolve(["enabled": enabled])
        }
    }

    @objc func isRangingAvailable(_ call: CAPPluginCall) {
        let available = implementation.isRangingAvailable()
        call.resolve(["available": available])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }
}
