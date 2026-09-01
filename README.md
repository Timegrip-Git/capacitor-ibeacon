# capacitor-ibeacon
<a href="https://capgo.app/"><img src="https://capgo.app/readme-banner.svg?repo=Cap-go/capacitor-ibeacon" alt="Capgo - Instant updates for Capacitor" /></a>

<div align="center">
  <h2><a href="https://capgo.app/?ref=plugin_ibeacon"> ➡️ Get Instant updates for your App with Capgo</a></h2>
  <h2><a href="https://capgo.app/consulting/?ref=plugin_ibeacon"> Missing a feature? We'll build the plugin for you 💪</a></h2>
</div>

iBeacon plugin for Capacitor - proximity detection and beacon region monitoring.

## Documentation

The most complete doc is available here: https://capgo.app/docs/plugins/ibeacon/

## Compatibility

| Plugin version | Capacitor compatibility | Maintained |
| -------------- | ----------------------- | ---------- |
| v8.\*.\*       | v8.\*.\*                | ✅          |
| v7.\*.\*       | v7.\*.\*                | On demand   |
| v6.\*.\*       | v6.\*.\*                | ❌          |
| v5.\*.\*       | v5.\*.\*                | ❌          |

> **iOS 18 or later is required.** Region monitoring is built on `CLMonitor` and authorization on
> `CLServiceSession`, both of which need iOS 18 for the per-event diagnostics the plugin relies on to
> tell "the beacon is not here" apart from "iOS is unable to say". Android is unaffected.

> **Note:** The major version of this plugin follows the major version of Capacitor. Use the version that matches your Capacitor installation (e.g., plugin v8 for Capacitor 8). Only the latest major version is actively maintained.

## Install

You can use our AI-Assisted Setup to install the plugin. Add the Capgo skills to your AI tool using the following command:

```bash
npx skills add https://github.com/cap-go/capacitor-skills --skill capacitor-plugins
```

Then use the following prompt:

```text
Use the `capacitor-plugins` skill from `cap-go/capacitor-skills` to install the `@capgo/capacitor-ibeacon` plugin in my project.
```

If you prefer Manual Setup, install the plugin by running the following commands and follow the platform-specific instructions below:

```bash
npm install @capgo/capacitor-ibeacon
npx cap sync
```

## Configuration

### iOS

#### Step 1: Configure Info.plist

Add the following keys to your `ios/App/App/Info.plist` file:

```xml
<!-- Required: Location permission for beacon detection -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>This app needs location access to detect nearby beacons</string>

<!-- Required for background monitoring: Always authorization -->
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>This app needs location access to monitor beacons in the background</string>

<!-- Required: Bluetooth usage (iOS 13+) -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app uses Bluetooth to detect nearby beacons</string>

<!-- Required for iOS 12 and earlier -->
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app uses Bluetooth to detect and advertise as beacons</string>

<!-- Required for background beacon monitoring -->
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>bluetooth-central</string>
</array>
```

#### Step 2: Enable Capabilities in Xcode

1. Open your project in Xcode: `ios/App/App.xcworkspace`
2. Select your app target
3. Go to the "Signing & Capabilities" tab
4. Click "+ Capability" and add "Background Modes"
5. Check the following options:
   - ✅ **Location updates** (required for background beacon monitoring)
   - ✅ **Uses Bluetooth LE accessories** (required for beacon detection)

#### Step 3: Start monitoring from your AppDelegate

**Required.** Monitoring has to exist before the Capacitor bridge does. iOS relaunches a terminated
app in the background to deliver a beacon crossing, within moments and long before a WebView and a
remotely hosted frontend could be ready, and `CLMonitor` is explicit that CoreLocation *stops*
monitoring a condition when an event is pending and nothing has opened the monitor to receive it. So
skipping this does not merely miss one crossing - it ends monitoring until something re-registers.

```swift
import Capacitor
import CapgoCapacitorIbeacon

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        CapacitorIbeacon.shared.start()
        return true
    }
}
```

Regions are adopted from the conditions iOS has persisted, so monitoring re-asserts itself on every
launch without the frontend having to ask - and keeps working even if the frontend never loads.
Region events are also posted on `NotificationCenter` under `CapacitorIbeaconRegionEvent`, so native
code in the host app can observe them without owning any of this.

#### Permissions Required

- **When In Use**: For foreground beacon ranging and monitoring
- **Always**: Required for background beacon monitoring (detecting beacons when app is not active)
- **Bluetooth**: Automatically granted on iOS 13+ when using CoreLocation for beacons
- **Precise Location**: Required. See below - beacons do not work without it, and an "Always" grant
  is not enough on its own.

#### Ranging is a foreground feature on iOS

Ranging (continuous proximity and RSSI, the `didRangeBeacons` event) only produces measurements while
the app process is running. iOS suspends the process shortly after it leaves the foreground, and
Apple's position is that background beacon ranging is not supported: on iOS 18 the ranging callback
keeps firing with **empty** beacon arrays once the display goes off, so it is the scan rather than
the process that stops. No background mode, session object or keep-alive changes this.

What the plugin does with that:

Automatic ranging is **off unless a region asks for it**, with `enableAutomaticRanging: true` on
`startMonitoringForRegion`. Monitoring is handed to the OS and costs almost nothing; ranging is a
continuous Bluetooth scan this app drives, and Apple's guidance is to prefer monitoring and to range
only while you need the measurements. If you only consume `didEnterRegion` and `didExitRegion`,
leaving it off saves the radio for as long as the user stands inside a region. With it on:

- **In the foreground**, entering the region starts ranging it and leaving stops it. Backgrounding
  suspends it; returning resumes it.
- **In the background**, a crossing gets a single ~10 second burst of ranging - the wake window the
  monitoring event itself provides - which captures the beacon's proximity at the moment of the
  crossing and then stops. Nothing is kept alive artificially.
- `startRangingBeaconsInRegion` / `stopRangingBeaconsInRegion` still work exactly as before and are
  tracked separately from the automatic behaviour, so an exit never cancels ranging you asked for,
  and your `stop` never cancels ranging a region occupancy still justifies.

If you need proximity at a moment when the app is not in the foreground, use the region crossing
itself as the signal - that is what it is for - rather than expecting a ranging stream.

#### Precise Location must be on

iOS will not monitor or range iBeacon regions when the user has turned **Precise Location** off, and
it reports this nowhere: no error, no failure callback, just silence that looks exactly like a beacon
nobody can hear. There is no way for an app to work around it - only the user can turn it back on, in
**Settings > (your app) > Location > Precise Location**.

The plugin reports the condition rather than trying to fix it:

- `getAuthorizationStatus()` returns `authorized_reduced_accuracy` in place of whichever grant is
  held - `authorized_always` or `authorized_when_in_use`. Treat it as "not usable for beacons": if
  your code branches on either of those values, handle this one too, and prompt the user to turn
  Precise Location back on.
- The accuracy is written to the native log at launch and in every monitoring audit.

> **Note**: The plugin uses CoreLocation for beacon detection, which handles Bluetooth scanning internally. Direct Bluetooth permissions are only needed if your app also uses CoreBluetooth for other purposes (e.g., advertising as a beacon).

### Android

The plugin automatically includes all required permissions and dependencies. No manual configuration needed.

**Permissions included:**
- Location permissions (fine, coarse, background)
- Bluetooth permissions (with proper legacy support for Android ≤11 and modern permissions for Android 12+)
- Foreground service permissions for background beacon scanning
- Boot completed permission for persistent monitoring

**Dependencies included:**
- AltBeacon Android Beacon Library (2.21.2)

**Important:** You still need to request permissions at runtime using the plugin's authorization methods (see API section below).

## API

All methods are available through the `CapacitorIbeacon` object:

```typescript
import { CapacitorIbeacon } from '@capgo/capacitor-ibeacon';
```

### startMonitoringForRegion(options: BeaconRegion)

Start monitoring for a beacon region. Triggers events when entering/exiting the region.

```typescript
await CapacitorIbeacon.startMonitoringForRegion({
  identifier: 'MyBeaconRegion',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D',
  major: 1,
  minor: 2
});
```

### stopMonitoringForRegion(options: BeaconRegion)

Stop monitoring for a beacon region.

```typescript
await CapacitorIbeacon.stopMonitoringForRegion({
  identifier: 'MyBeaconRegion',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D'
});
```

### startRangingBeaconsInRegion(options: BeaconRegion)

Start ranging beacons in a region. Provides continuous distance updates.

On iOS this is foreground-only in practice - see [Ranging is a foreground feature on
iOS](#ranging-is-a-foreground-feature-on-ios). A region monitored with `enableAutomaticRanging: true`
already ranges itself while occupied and the app is in the foreground, so this call is for ranging a
region you are not monitoring, for a region that did not ask for it, or for keeping ranging on across
a region exit.

```typescript
await CapacitorIbeacon.startRangingBeaconsInRegion({
  identifier: 'MyBeaconRegion',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D'
});
```

### stopRangingBeaconsInRegion(options: BeaconRegion)

Stop ranging beacons in a region.

```typescript
await CapacitorIbeacon.stopRangingBeaconsInRegion({
  identifier: 'MyBeaconRegion',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D'
});
```

### startAdvertising(options: BeaconAdvertisingOptions)

Start advertising the device as an iBeacon (iOS only).

```typescript
await CapacitorIbeacon.startAdvertising({
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D',
  major: 1,
  minor: 2,
  identifier: 'MyBeacon'
});
```

### stopAdvertising()

Stop advertising the device as an iBeacon (iOS only).

```typescript
await CapacitorIbeacon.stopAdvertising();
```

### requestWhenInUseAuthorization()

Request "When In Use" location authorization.

```typescript
const { status } = await CapacitorIbeacon.requestWhenInUseAuthorization();
console.log('Authorization status:', status);
```

### requestAlwaysAuthorization()

On iOS this also takes the `CLServiceSession` that iOS 18 requires: an app holding "always"
authorization but no session receives **no** monitoring events while it is not in-use. The plugin
records that always-operation was configured and re-takes the session on every launch, including
background relaunches - so call this once from the foreground when the user opts into background
monitoring, and the plugin keeps it held from then on.

Request "Always" location authorization (required for background monitoring).

```typescript
const { status } = await CapacitorIbeacon.requestAlwaysAuthorization();
console.log('Authorization status:', status);
```

### getAuthorizationStatus()

Get current location authorization status.

```typescript
const { status } = await CapacitorIbeacon.getAuthorizationStatus();
// status: 'not_determined' | 'restricted' | 'denied' | 'authorized_always'
//       | 'authorized_when_in_use' | 'authorized_reduced_accuracy'
// iOS: 'authorized_reduced_accuracy' means Precise Location is off, so beacons cannot work.
```

### isBluetoothEnabled()

Check if Bluetooth is enabled on the device.

On iOS this reports whether **this app** can currently use Bluetooth, and never prompts. iOS offers no
way to read the radio without first holding Bluetooth permission, and beacon monitoring never needs
that permission - so it resolves to `false` until something has asked for it, which only
`startAdvertising` does. Do not gate monitoring or ranging on this; `getAuthorizationStatus()` reports
the permission they actually depend on.

```typescript
const { enabled } = await CapacitorIbeacon.isBluetoothEnabled();
if (!enabled) {
  console.log('Please enable Bluetooth');
}
```

### isRangingAvailable()

Check if ranging is available on the device.

```typescript
const { available } = await CapacitorIbeacon.isRangingAvailable();
```

### enableARMAFilter(options: { enabled: boolean })

Enable ARMA filtering for distance calculations (Android only).

```typescript
await CapacitorIbeacon.enableARMAFilter({ enabled: true });
```

### Android background scanning

Android 8+ requires a foreground service to keep Bluetooth scanning alive in the background. You can opt in once and the plugin will automatically
toggle background scanning when the app moves between foreground and background.

```typescript
// Enable background scanning globally (Android only)
await CapacitorIbeacon.enableBackgroundMode({ enabled: true });

// Or opt in per call
await CapacitorIbeacon.startMonitoringForRegion({
  identifier: 'MyBeaconRegion',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D',
  enableBackgroundMode: true,
});
```

You can also enable it via Capacitor config:

```typescript
// capacitor.config.ts
plugins: {
  CapacitorIbeacon: {
    enableBackgroundMode: true,
  },
}
```

## Events

Listen to beacon events using Capacitor's event system:

```typescript
import { CapacitorIbeacon } from '@capgo/capacitor-ibeacon';
import { PluginListenerHandle } from '@capacitor/core';

// Listen for ranging events
const rangingListener: PluginListenerHandle = await CapacitorIbeacon.addListener(
  'didRangeBeacons',
  (data) => {
    console.log('Beacons detected:', data.beacons);
    data.beacons.forEach(beacon => {
      console.log(`Beacon: ${beacon.uuid}, Distance: ${beacon.accuracy}m, Proximity: ${beacon.proximity}`);
    });
  }
);

// Listen for region enter events
const enterListener: PluginListenerHandle = await CapacitorIbeacon.addListener(
  'didEnterRegion',
  (data) => {
    console.log('Entered region:', data.region.identifier);
  }
);

// Listen for region exit events
const exitListener: PluginListenerHandle = await CapacitorIbeacon.addListener(
  'didExitRegion',
  (data) => {
    console.log('Exited region:', data.region.identifier);
  }
);

// Listen for region state changes
const stateListener: PluginListenerHandle = await CapacitorIbeacon.addListener(
  'didDetermineStateForRegion',
  (data) => {
    console.log(`Region ${data.region.identifier}: ${data.state}`);
  }
);

// Clean up listeners when done
rangingListener.remove();
enterListener.remove();
exitListener.remove();
stateListener.remove();
```

## Complete Example

```typescript
import { CapacitorIbeacon } from '@capgo/capacitor-ibeacon';

// Define your beacon region
const beaconRegion = {
  identifier: 'MyStore',
  uuid: 'B9407F30-F5F8-466E-AFF9-25556B57FE6D',
  major: 1
};

async function setupBeaconMonitoring() {
  try {
    // Request permission
    const { status } = await CapacitorIbeacon.requestWhenInUseAuthorization();
    
    if (status === 'authorized_reduced_accuracy') {
      // iOS only: granted, but Precise Location is off - beacons report nothing at all.
      console.error('Turn on Precise Location in Settings for this app');
      return;
    }

    if (status !== 'authorized_when_in_use' && status !== 'authorized_always') {
      console.error('Location permission denied');
      return;
    }

    // Check if Bluetooth is enabled
    const { enabled } = await CapacitorIbeacon.isBluetoothEnabled();
    if (!enabled) {
      console.error('Bluetooth is not enabled');
      return;
    }

    // Set up event listeners
    await CapacitorIbeacon.addListener('didEnterRegion', (data) => {
      console.log('Welcome! You entered:', data.region.identifier);
      // Show welcome notification or trigger action
    });

    await CapacitorIbeacon.addListener('didExitRegion', (data) => {
      console.log('Goodbye! You left:', data.region.identifier);
    });

    await CapacitorIbeacon.addListener('didRangeBeacons', (data) => {
      data.beacons.forEach(beacon => {
        console.log(`Beacon ${beacon.minor}: ${beacon.proximity} (${beacon.accuracy.toFixed(2)}m)`);
      });
    });

    // Start monitoring
    await CapacitorIbeacon.startMonitoringForRegion(beaconRegion);
    console.log('Started monitoring for beacons');

    // Start ranging for distance updates
    await CapacitorIbeacon.startRangingBeaconsInRegion(beaconRegion);
    console.log('Started ranging beacons');

  } catch (error) {
    console.error('Error setting up beacon monitoring:', error);
  }
}

// Call the setup function
setupBeaconMonitoring();
```

## TypeScript Types

### BeaconRegion

```typescript
interface BeaconRegion {
  identifier: string;
  uuid: string;
  major?: number;
  minor?: number;
  notifyEntryStateOnDisplay?: boolean;
}
```

### Beacon

```typescript
interface Beacon {
  uuid: string;
  major: number;
  minor: number;
  rssi: number;
  proximity: 'immediate' | 'near' | 'far' | 'unknown';
  accuracy: number;
}
```

### BeaconAdvertisingOptions

```typescript
interface BeaconAdvertisingOptions {
  uuid: string;
  major: number;
  minor: number;
  identifier: string;
  measuredPower?: number;
}
```

## Proximity Values

- **immediate**: Very close to the beacon (within a few centimeters)
- **near**: Relatively close to the beacon (within a couple of meters)
- **far**: Further away from the beacon (10+ meters)
- **unknown**: Distance cannot be determined

## Important Notes

1. **iOS Background Monitoring**: To monitor beacons in the background, you need:
   - "Always" location authorization (`requestAlwaysAuthorization()`)
   - Background Modes capability enabled in Xcode
   - `UIBackgroundModes` with both `location` and `bluetooth-central` in Info.plist

2. **iOS Xcode Configuration**: Adding Info.plist keys alone is not enough. You **must** enable Background Modes capability in Xcode (see Configuration section above). This is the most common setup issue.

3. **Android Library**: This plugin includes the AltBeacon Android Beacon Library (2.21.2) automatically.

4. **Battery Usage**: Continuous beacon ranging can consume significant battery. Consider using monitoring (which is more battery-efficient) and only start ranging when needed.

5. **UUID Format**: UUIDs must be in the standard format: `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`

6. **Major/Minor Values**: These are optional 16-bit unsigned integers (0-65535) used to identify specific beacons within a UUID.

7. **Permissions**: Always request and check permissions before starting beacon operations.

## Troubleshooting

### iOS Issues

**"Beacons not detected" or "Plugin not working"**

1. **Verify Info.plist configuration**:
   - Ensure all required keys are present (see Configuration section above)
   - Check that permission descriptions are meaningful and not empty

2. **Enable Background Modes in Xcode**:
   - This is a common issue - you MUST enable capabilities in Xcode, not just add Info.plist keys
   - Open `ios/App/App.xcworkspace` in Xcode
   - Select your target → "Signing & Capabilities"
   - Add "Background Modes" capability
   - Check "Location updates" and "Uses Bluetooth LE accessories"

3. **Request proper authorization**:
   ```typescript
   // For foreground detection only
   await CapacitorIbeacon.requestWhenInUseAuthorization();
   
   // For background monitoring (required for region enter/exit events when app is closed)
   await CapacitorIbeacon.requestAlwaysAuthorization();
   ```

4. **Check Bluetooth is enabled**:
   ```typescript
   const { enabled } = await CapacitorIbeacon.isBluetoothEnabled();
   if (!enabled) {
     // Prompt user to enable Bluetooth in Settings
   }
   ```

5. **Verify authorization status**:
   ```typescript
   const { status } = await CapacitorIbeacon.getAuthorizationStatus();
   console.log('Auth status:', status);
   // Should be 'authorized_when_in_use' or 'authorized_always'.
   // On iOS, 'authorized_reduced_accuracy' means Precise Location is off - beacons will stay silent.
   ```

6. **Check device compatibility**:
   - iBeacon requires iOS 7.0+
   - Some features require specific iOS versions (e.g., ranging in background)
   - Use `isRangingAvailable()` to check device support

**"No events firing" or "addListener not working"**

- Ensure you set up listeners **before** starting monitoring/ranging:
  ```typescript
  // Set up listeners first
  await CapacitorIbeacon.addListener('didEnterRegion', (data) => {
    console.log('Entered:', data.region.identifier);
  });
  
  // Then start monitoring
  await CapacitorIbeacon.startMonitoringForRegion({
    identifier: 'MyRegion',
    uuid: 'YOUR-UUID-HERE'
  });
  ```

**Background monitoring not working**

- Requires "Always" authorization: `requestAlwaysAuthorization()`
- Must have `UIBackgroundModes` with `location` and `bluetooth-central` in Info.plist
- Must have Background Modes capability enabled in Xcode
- iOS may throttle background scanning to preserve battery

### Android Issues

See the Android permissions section in the Configuration above. Most Android issues relate to:
- Not requesting runtime permissions
- Missing foreground service on Android 8+
- Bluetooth not enabled

For detailed Android troubleshooting, check the AltBeacon library documentation.

## Credits

This plugin was inspired by [cordova-plugin-ibeacon](https://github.com/petermetz/cordova-plugin-ibeacon) and adapted for Capacitor.

## License

MIT

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to contribute to this plugin.
