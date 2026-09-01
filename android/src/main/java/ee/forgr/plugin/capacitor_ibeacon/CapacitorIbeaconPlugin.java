package ee.forgr.plugin.capacitor_ibeacon;

import android.Manifest;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothManager;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.core.app.ActivityCompat;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.altbeacon.beacon.Beacon;
import org.altbeacon.beacon.BeaconManager;
import org.altbeacon.beacon.BeaconParser;
import org.altbeacon.beacon.Identifier;
import org.altbeacon.beacon.MonitorNotifier;
import org.altbeacon.beacon.RangeNotifier;
import org.altbeacon.beacon.Region;
import org.altbeacon.beacon.Settings;
import org.altbeacon.beacon.service.ArmaRssiFilter;
import org.altbeacon.beacon.service.RunningAverageRssiFilter;

@CapacitorPlugin(
    name = "CapacitorIbeacon",
    permissions = {
        @Permission(alias = "location", strings = { Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION }),
        @Permission(alias = "backgroundLocation", strings = { Manifest.permission.ACCESS_BACKGROUND_LOCATION }),
        @Permission(alias = "bluetooth", strings = { Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN }),
        @Permission(alias = "bluetoothScan", strings = { Manifest.permission.BLUETOOTH_SCAN }),
        @Permission(alias = "bluetoothConnect", strings = { Manifest.permission.BLUETOOTH_CONNECT })
    }
)
public class CapacitorIbeaconPlugin extends Plugin {

    private final String pluginVersion = "8.1.34";
    private static final String FOREGROUND_CHANNEL_ID = "beacon_service_channel";
    private static final int FOREGROUND_NOTIFICATION_ID = 456;
    private static final String IBEACON_LAYOUT = "m:2-3=0215,i:4-19,i:20-21,i:22-23,p:24-24";
    private static final String TAG = "CapacitorIbeacon";

    /*
      A region counts as exited purely on "not seen for longer than this", evaluated at the end of a
      scan cycle - there is no consecutive-miss requirement, so this is the entire tolerance for a
      beacon that is present but momentarily unheard. Measured over a night with a static phone and
      two beacons in range: missing a few listening windows in a row left it deaf for 60-80s at a
      time, one outlier at 183s, and both beacons went deaf in the same millisecond - it is the
      phone's receiver, not the beacons. AltBeacon's own default of 10s is far below that, and 60s
      still produced an exit followed by an enter 28 milliseconds later.

      Three minutes covers all but that outlier, at the price of reporting a genuine exit that much
      later. That is the better error: a late exit is still true, a spurious one never was.
    */
    private static final long REGION_EXIT_PERIOD = 180000L;

    // A scan outlives the Activity that started it: foreground service scanning keeps the process,
    // the service binding and the BeaconManager singleton alive while the Activity - and with it this
    // plugin instance, its bridge and its WebView - is destroyed and later recreated. All state that
    // describes the scan therefore lives for as long as the process does, not as long as an instance,
    // so a recreated instance takes over what its predecessor left running instead of trying to set
    // it up a second time.
    private static final Map<String, Region> monitoredRegions = new ConcurrentHashMap<>();
    private static final Map<String, Region> rangedRegions = new ConcurrentHashMap<>();
    private static MonitorNotifier monitorNotifier;
    private static RangeNotifier rangeNotifier;
    private static boolean backgroundModeEnabled = false;
    private static boolean foregroundServiceEnabled = false;

    // The instance whose bridge is currently alive, or null while no Activity is up. Scan callbacks
    // are routed through it so they always reach the live WebView, and are dropped when there is none
    // rather than being handed to a destroyed bridge.
    private static volatile CapacitorIbeaconPlugin activeInstance;

    private BeaconManager beaconManager;

    // Nothing in here may throw: Bridge.registerPlugin() turns any exception into a PluginLoadException
    // and then never registers the plugin, so every plugin method would reject with "not implemented on
    // android" for the rest of the app run.
    @Override
    public void load() {
        try {
            /*
              For diagnosing what a scan actually heard - AltBeacon states why it declared a region
              exited, and how long ago the region was last seen, which is the difference between an
              exit period that is too tight and a scan that stopped receiving. It logs a line per scan
              cycle and per detection, so this is meant for a diagnostic run rather than for good.
            */
            Boolean configDebugLogging = getConfig().getBoolean("enableDebugLogging", false);
            boolean debugLogging = configDebugLogging != null && configDebugLogging;
            if (debugLogging) {
                BeaconManager.setDebug(true);
            }

            // Initialize beacon manager
            beaconManager = BeaconManager.getInstanceForApplication(getContext());
            activeInstance = this;

            // Set up iBeacon layout parser, unless it is already in the application-wide list
            if (!hasIBeaconParser()) {
                beaconManager.getBeaconParsers().add(new BeaconParser().setBeaconLayout(IBEACON_LAYOUT));
            }

            // Unlike the scan settings below, this is a static that takes effect immediately, so it
            // is applied whether or not a scan is already running.
            BeaconManager.setRegionExitPeriod(REGION_EXIT_PERIOD);

            if (beaconManager.isAnyConsumerBound()) {
                // A scan is already running in this process, so the settings below may no longer be
                // applied - AltBeacon throws once a consumer is bound. Take over the running scan
                // instead, including anything a previous process left actively monitored.
                if (beaconManager.getForegroundServiceNotification() != null) {
                    foregroundServiceEnabled = true;
                }
                for (Region region : beaconManager.getMonitoredRegions()) {
                    monitoredRegions.putIfAbsent(region.getUniqueId(), region);
                }
                for (Region region : beaconManager.getRangedRegions()) {
                    rangedRegions.putIfAbsent(region.getUniqueId(), region);
                }
            } else {
                // Configure for background scanning - enable long-running scanning mode
                // This is critical for beacon detection when app is in background
                beaconManager.setEnableScheduledScanJobs(false);

                // Prevent Android from downgrading long-running BLE scans to opportunistic mode
                beaconManager.adjustSettings(new Settings.Builder().setLongScanForcingEnabled(true).build());

                /*
                  Background scan periods, in milliseconds. AltBeacon's own defaults are 10s of
                  scanning every 5 minutes - 3% of the time. A 30 second gap puts this at 25%, or
                  roughly 15 minutes of radio per hour, around the clock.

                  It was 5 seconds, which is 67% and closer to 40 minutes an hour, and the reasoning
                  behind that turned out to be double-counting. The tight gap was added to stop
                  spurious exits, on the grounds that a beacon heard in only some windows is taken
                  for gone - and then REGION_EXIT_PERIOD was widened to three minutes for the same
                  reason, which is the far cheaper of the two remedies and made the first redundant.

                  The measurements are what settle it. Every spurious exit came from the phone's
                  receiver going deaf for 60-80 seconds at a stretch, hearing nothing from any
                  beacon; scanning more often during a deafness hears no more than scanning less
                  often does. What answers it is the exit period being longer than the deafness, and
                  three minutes is. Meanwhile a working scan hears a beacon in range every 1.3
                  seconds, so a 10 second window has a hundred chances to notice it and needs
                  nothing like 67% of the clock to succeed.

                  What this does cost is entry latency: a beacon walked past is now noticed up to 30
                  seconds later rather than up to 5. Exits are unaffected - REGION_EXIT_PERIOD is
                  measured in wall-clock time since the beacon was last seen, not in missed windows.
                */
                beaconManager.setBackgroundBetweenScanPeriod(30000L); // 30 seconds between scans
                beaconManager.setBackgroundScanPeriod(10000L); // 10 seconds scan duration

                // Configure foreground scan periods
                beaconManager.setForegroundBetweenScanPeriod(0L); // Continuous scanning in foreground
                beaconManager.setForegroundScanPeriod(1100L); // Standard scan period
            }

            // Again, deliberately: a Settings object carries a debug flag of its own, so the
            // adjustSettings() above silently turns logging back off. That is how the first
            // diagnostic run came back with nothing logged past load().
            if (debugLogging) {
                BeaconManager.setDebug(true);
            }

            addNotifiersIfNeeded();

            Boolean configBackgroundMode = getConfig().getBoolean("enableBackgroundMode", false);
            if (configBackgroundMode != null && configBackgroundMode) {
                backgroundModeEnabled = true;
            }
        } catch (Exception e) {
            android.util.Log.e(TAG, "Beacon monitoring was not fully initialized", e);
        }
    }

    @Override
    protected void handleOnDestroy() {
        // Stop routing callbacks at a bridge that is about to die. The scan itself, its binding and its
        // notifiers stay in place for the next instance to take over - that is what makes monitoring
        // survive the Activity - unless nothing is left to watch, or unless it is running without a
        // foreground service and so has no business outliving the Activity in the first place.
        if (activeInstance == this) {
            activeInstance = null;
        }

        /*
          Nothing is torn down for the Activity's sake any more. AltBeacon binds and unbinds itself
          around the regions it is watching, so a scan that should continue continues and one with
          nothing left to watch has already gone - and without a foreground service there is nothing
          holding this process up regardless.
        */
        releaseIfNothingLeftToWatch();
        super.handleOnDestroy();
    }

    private boolean hasIBeaconParser() {
        for (BeaconParser parser : beaconManager.getBeaconParsers()) {
            if (IBEACON_LAYOUT.equals(parser.getLayout())) {
                return true;
            }
        }
        return false;
    }

    // The notifier sets are application-wide, so a single pair per process is registered and left in
    // place. They hold no reference to any instance: each callback is dispatched to whichever instance
    // is live at that moment, so a destroyed one is never called and never leaks through them.
    private void addNotifiersIfNeeded() {
        if (monitorNotifier == null) {
            monitorNotifier = new MonitorNotifier() {
                @Override
                public void didEnterRegion(Region region) {
                    CapacitorIbeaconPlugin plugin = dispatchTarget("didEnterRegion", region.getUniqueId());
                    if (plugin != null) {
                        plugin.notifyDidEnterRegion(region);
                    }
                }

                @Override
                public void didExitRegion(Region region) {
                    CapacitorIbeaconPlugin plugin = dispatchTarget("didExitRegion", region.getUniqueId());
                    if (plugin != null) {
                        plugin.notifyDidExitRegion(region);
                    }
                }

                @Override
                public void didDetermineStateForRegion(int state, Region region) {
                    CapacitorIbeaconPlugin plugin = dispatchTarget(
                        "didDetermineStateForRegion(" + (state == MonitorNotifier.INSIDE ? "inside" : "outside") + ")",
                        region.getUniqueId()
                    );
                    if (plugin != null) {
                        plugin.notifyDidDetermineStateForRegion(state, region);
                    }
                }
            };
            beaconManager.addMonitorNotifier(monitorNotifier);
        }

        if (rangeNotifier == null) {
            rangeNotifier = new RangeNotifier() {
                @Override
                public void didRangeBeaconsInRegion(Collection<Beacon> beacons, Region region) {
                    CapacitorIbeaconPlugin plugin = activeInstance;
                    if (plugin != null) {
                        plugin.notifyDidRangeBeacons(beacons, region);
                    }
                }
            };
            beaconManager.addRangeNotifier(rangeNotifier);
        }
    }

    /*
      Region events only reach JS while an Activity is up: the scan keeps running behind a destroyed
      one, but Plugin.notifyListeners() discards an event that has no listener, so it is lost rather
      than delayed. Whether that happened is otherwise invisible - Capacitor's own logging is off in
      a release build - hence this log line at the one point where it can still be told. Region
      transitions are rare enough for this to be cheap. Ranging is deliberately not logged.
    */
    private static CapacitorIbeaconPlugin dispatchTarget(String event, String regionIdentifier) {
        CapacitorIbeaconPlugin plugin = activeInstance;
        android.util.Log.i(TAG, event + " " + regionIdentifier + (plugin == null ? ": dropped, no live bridge" : ": to bridge"));
        return plugin;
    }

    @PluginMethod
    public void startMonitoringForRegion(PluginCall call) {
        String identifier = call.getString("identifier");
        String uuid = call.getString("uuid");
        Integer major = call.getInt("major");
        Integer minor = call.getInt("minor");
        Boolean enableBackgroundMode = call.getBoolean("enableBackgroundMode");

        if (identifier == null || uuid == null) {
            call.reject("Missing required parameters");
            return;
        }

        try {
            if (enableBackgroundMode != null) {
                setBackgroundModeEnabled(enableBackgroundMode);
            }
            prepareToScan();
            Region region = createRegion(identifier, uuid, major, minor);
            monitoredRegions.put(identifier, region);
            beaconManager.startMonitoring(region);
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to start monitoring", e);
        }
    }

    @PluginMethod
    public void stopMonitoringForRegion(PluginCall call) {
        String identifier = call.getString("identifier");
        String uuid = call.getString("uuid");

        if (identifier == null || uuid == null) {
            call.reject("Missing required parameters");
            return;
        }

        try {
            Region region = monitoredRegions.get(identifier);
            if (region != null) {
                beaconManager.stopMonitoring(region);
                monitoredRegions.remove(identifier);
            }
            releaseIfNothingLeftToWatch();
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to stop monitoring", e);
        }
    }

    @PluginMethod
    public void startRangingBeaconsInRegion(PluginCall call) {
        String identifier = call.getString("identifier");
        String uuid = call.getString("uuid");
        Integer major = call.getInt("major");
        Integer minor = call.getInt("minor");
        Boolean enableBackgroundMode = call.getBoolean("enableBackgroundMode");

        if (identifier == null || uuid == null) {
            call.reject("Missing required parameters");
            return;
        }

        try {
            if (enableBackgroundMode != null) {
                setBackgroundModeEnabled(enableBackgroundMode);
            }
            prepareToScan();
            Region region = createRegion(identifier, uuid, major, minor);
            rangedRegions.put(identifier, region);
            beaconManager.startRangingBeacons(region);
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to start ranging", e);
        }
    }

    @PluginMethod
    public void stopRangingBeaconsInRegion(PluginCall call) {
        String identifier = call.getString("identifier");
        String uuid = call.getString("uuid");

        if (identifier == null || uuid == null) {
            call.reject("Missing required parameters");
            return;
        }

        try {
            Region region = rangedRegions.get(identifier);
            if (region != null) {
                beaconManager.stopRangingBeacons(region);
                rangedRegions.remove(identifier);
            }
            releaseIfNothingLeftToWatch();
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to stop ranging", e);
        }
    }

    @PluginMethod
    public void startAdvertising(PluginCall call) {
        call.reject("Advertising is not supported on Android through this API");
    }

    @PluginMethod
    public void stopAdvertising(PluginCall call) {
        call.reject("Advertising is not supported on Android through this API");
    }

    @PluginMethod
    public void requestWhenInUseAuthorization(PluginCall call) {
        // On Android 12+, also need to request BLUETOOTH_SCAN and BLUETOOTH_CONNECT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothScan =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED;
            boolean hasBluetoothConnect =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED;

            if (!hasBluetoothScan) {
                requestPermissionForAlias("bluetoothScan", call, "bluetoothScanPermissionCallback");
                return;
            }
            if (!hasBluetoothConnect) {
                requestPermissionForAlias("bluetoothConnect", call, "bluetoothConnectPermissionCallback");
                return;
            }
        }

        if (
            ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissionForAlias("location", call, "locationPermissionCallback");
        } else {
            JSObject ret = new JSObject();
            ret.put("status", "authorized_when_in_use");
            call.resolve(ret);
        }
    }

    @PluginMethod
    public void requestAlwaysAuthorization(PluginCall call) {
        // First ensure we have foreground location permission
        boolean hasFineLocation =
            ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;

        if (!hasFineLocation) {
            // Must request foreground location first before background
            requestPermissionForAlias("location", call, "foregroundLocationForBackgroundCallback");
            return;
        }

        // On Android 10+ (Q), need to request ACCESS_BACKGROUND_LOCATION separately
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            boolean hasBackgroundLocation =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
                PackageManager.PERMISSION_GRANTED;

            if (!hasBackgroundLocation) {
                requestPermissionForAlias("backgroundLocation", call, "backgroundLocationPermissionCallback");
                return;
            }
        }

        // On Android 12+, also need BLUETOOTH_SCAN and BLUETOOTH_CONNECT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothScan =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED;
            boolean hasBluetoothConnect =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED;

            if (!hasBluetoothScan) {
                requestPermissionForAlias("bluetoothScan", call, "bluetoothScanForBackgroundCallback");
                return;
            }
            if (!hasBluetoothConnect) {
                requestPermissionForAlias("bluetoothConnect", call, "bluetoothConnectForBackgroundCallback");
                return;
            }
        }

        JSObject ret = new JSObject();
        ret.put("status", "authorized_always");
        call.resolve(ret);
    }

    @PermissionCallback
    private void locationPermissionCallback(PluginCall call) {
        JSObject ret = new JSObject();
        if (getPermissionState("location") == PermissionState.GRANTED) {
            ret.put("status", "authorized_when_in_use");
        } else {
            ret.put("status", "denied");
        }
        call.resolve(ret);
    }

    @PluginMethod
    public void getAuthorizationStatus(PluginCall call) {
        JSObject ret = new JSObject();

        boolean hasFineLocation =
            ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;

        if (!hasFineLocation) {
            ret.put("status", "denied");
            call.resolve(ret);
            return;
        }

        if (!hasBluetoothPermissions()) {
            ret.put("status", "denied");
            call.resolve(ret);
            return;
        }

        // On Android 10+, check for background location
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            boolean hasBackgroundLocation =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
                PackageManager.PERMISSION_GRANTED;

            if (hasBackgroundLocation) {
                ret.put("status", "authorized_always");
            } else {
                ret.put("status", "authorized_when_in_use");
            }
        } else {
            // Below Android 10, foreground permission is enough for background
            ret.put("status", "authorized_always");
        }

        call.resolve(ret);
    }

    @PermissionCallback
    private void foregroundLocationForBackgroundCallback(PluginCall call) {
        if (getPermissionState("location") == PermissionState.GRANTED) {
            // Now request background location
            requestAlwaysAuthorization(call);
        } else {
            JSObject ret = new JSObject();
            ret.put("status", "denied");
            call.resolve(ret);
        }
    }

    @PermissionCallback
    private void backgroundLocationPermissionCallback(PluginCall call) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            boolean hasBackgroundLocation =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
                PackageManager.PERMISSION_GRANTED;

            if (hasBackgroundLocation) {
                // Continue with bluetooth permissions on Android 12+
                requestAlwaysAuthorization(call);
            } else {
                JSObject ret = new JSObject();
                ret.put("status", "authorized_when_in_use");
                call.resolve(ret);
            }
        } else {
            requestAlwaysAuthorization(call);
        }
    }

    @PermissionCallback
    private void bluetoothScanPermissionCallback(PluginCall call) {
        // Check if BLUETOOTH_SCAN was granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothScan =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED;

            if (hasBluetoothScan) {
                // Continue with the original request
                requestWhenInUseAuthorization(call);
            } else {
                // Permission denied, resolve with denied status
                JSObject ret = new JSObject();
                ret.put("status", "denied");
                call.resolve(ret);
            }
        } else {
            // Continue with the original request on older versions
            requestWhenInUseAuthorization(call);
        }
    }

    @PermissionCallback
    private void bluetoothConnectPermissionCallback(PluginCall call) {
        // Check if BLUETOOTH_CONNECT was granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothConnect =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED;

            if (hasBluetoothConnect) {
                // Continue with the original request
                requestWhenInUseAuthorization(call);
            } else {
                // Permission denied, resolve with denied status
                JSObject ret = new JSObject();
                ret.put("status", "denied");
                call.resolve(ret);
            }
        } else {
            // Continue with the original request on older versions
            requestWhenInUseAuthorization(call);
        }
    }

    @PermissionCallback
    private void bluetoothScanForBackgroundCallback(PluginCall call) {
        // Check if BLUETOOTH_SCAN was granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothScan =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED;

            if (hasBluetoothScan) {
                // Continue with the background authorization flow
                requestAlwaysAuthorization(call);
            } else {
                // Permission denied, check what we can offer
                boolean hasFineLocation =
                    ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED;

                JSObject ret = new JSObject();
                if (hasFineLocation) {
                    ret.put("status", "authorized_when_in_use");
                } else {
                    ret.put("status", "denied");
                }
                call.resolve(ret);
            }
        } else {
            // Continue with the background authorization flow on older versions
            requestAlwaysAuthorization(call);
        }
    }

    @PermissionCallback
    private void bluetoothConnectForBackgroundCallback(PluginCall call) {
        // Check if BLUETOOTH_CONNECT was granted
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            boolean hasBluetoothConnect =
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED;

            if (hasBluetoothConnect) {
                // Continue with the background authorization flow
                requestAlwaysAuthorization(call);
            } else {
                // Permission denied, check what we can offer
                boolean hasFineLocation =
                    ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.ACCESS_FINE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED;

                JSObject ret = new JSObject();
                if (hasFineLocation) {
                    ret.put("status", "authorized_when_in_use");
                } else {
                    ret.put("status", "denied");
                }
                call.resolve(ret);
            }
        } else {
            // Continue with the background authorization flow on older versions
            requestAlwaysAuthorization(call);
        }
    }

    @PluginMethod
    public void isBluetoothEnabled(PluginCall call) {
        JSObject ret = new JSObject();
        BluetoothAdapter bluetoothAdapter = bluetoothAdapter();
        ret.put("enabled", bluetoothAdapter != null && bluetoothAdapter.isEnabled());
        call.resolve(ret);
    }

    @PluginMethod
    public void isRangingAvailable(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("available", bluetoothAdapter() != null);
        call.resolve(ret);
    }

    /*
      BluetoothAdapter.getDefaultAdapter() is deprecated, and was never quite right either: it
      answers for the process rather than for a context, which is why the platform replaced it with
      an adapter obtained from the system service. Null where the device has no Bluetooth at all,
      which is what isRangingAvailable() reports.
    */
    private BluetoothAdapter bluetoothAdapter() {
        BluetoothManager manager = getContext().getSystemService(BluetoothManager.class);
        return manager == null ? null : manager.getAdapter();
    }

    /*
      Selects which RSSI filter smooths the readings a distance is computed from.

      It used to set a distance calculator instead, and not even a different one: the
      ModelSpecificDistanceCalculator it installed is what AltBeacon already uses, so enabling the
      "ARMA filter" replaced the default with the default and no ARMA filter existed anywhere in the
      process. `enabled: false` did nothing at all, having nothing to undo.

      ARMA is one of the two RssiFilter implementations AltBeacon ships, chosen through
      setRssiFilterImplClass. Off restores RunningAverageRssiFilter, which is what RangedBeacon falls
      back to when nothing is set - named explicitly rather than cleared to null, so the library has
      no cause to log that it is defaulting.

      Applies to beacons first seen after this call: the filter is built per ranged beacon when that
      beacon is first ranged, so anything already in range keeps the filter it started with.
    */
    @PluginMethod
    public void enableARMAFilter(PluginCall call) {
        Boolean enabled = call.getBoolean("enabled", false);
        boolean wantArma = enabled != null && enabled;

        try {
            BeaconManager.setRssiFilterImplClass(wantArma ? ArmaRssiFilter.class : RunningAverageRssiFilter.class);
            android.util.Log.i(TAG, "RSSI filter set to " + (wantArma ? "ARMA" : "running average"));
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to set the RSSI filter", e);
        }
    }

    @PluginMethod
    public void enableBackgroundMode(PluginCall call) {
        Boolean enabled = call.getBoolean("enabled", true);
        boolean wantBackground = enabled != null && enabled;
        try {
            if (!ensureForegroundServiceMatches(wantBackground)) {
                call.reject("Failed to enable foreground service scanning");
                return;
            }
            setBackgroundModeEnabled(wantBackground);
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to enable background mode", e);
        }
    }

    @PluginMethod
    public void setBackgroundScanPeriod(PluginCall call) {
        // The same values load() applies, so that omitting one of these does not quietly change it.
        // A caller adjusting only scanPeriod used to have the gap fall from 30s to 15s underneath
        // them, doubling the scan duty cycle as a side effect of a call about something else.
        long scanPeriod = longOptionFromCall(call, "scanPeriod", 10000L);
        long betweenScanPeriod = longOptionFromCall(call, "betweenScanPeriod", 30000L);

        try {
            beaconManager.setBackgroundScanPeriod(scanPeriod);
            beaconManager.setBackgroundBetweenScanPeriod(betweenScanPeriod);
            if (beaconManager.isAnyConsumerBound()) {
                beaconManager.updateScanPeriods();
            }
            call.resolve();
        } catch (Exception e) {
            call.reject("Failed to set background scan period", e);
        }
    }

    @PluginMethod
    public void getPluginVersion(final PluginCall call) {
        try {
            final JSObject ret = new JSObject();
            ret.put("version", this.pluginVersion);
            call.resolve(ret);
        } catch (final Exception e) {
            call.reject("Could not get plugin version", e);
        }
    }

    // Helper methods

    // Capacitor's PluginCall.getLong() only reads Java Long values. JS numbers that
    // fit in 32 bits cross the bridge as Integer, so optLong is required.
    static long longOptionFromCall(PluginCall call, String key, long defaultValue) {
        return call.getData().optLong(key, defaultValue);
    }

    private boolean hasBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return (
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ActivityCompat.checkSelfPermission(getContext(), Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
            );
        }
        return true;
    }

    private Region createRegion(String identifier, String uuid, Integer major, Integer minor) {
        List<Identifier> identifiers = new ArrayList<>();
        identifiers.add(Identifier.parse(uuid));

        if (major != null) {
            identifiers.add(Identifier.fromInt(major));
        }
        if (minor != null) {
            identifiers.add(Identifier.fromInt(minor));
        }

        return new Region(identifier, identifiers);
    }

    private void notifyDidEnterRegion(Region region) {
        JSObject ret = new JSObject();
        ret.put("region", serializeRegion(region));
        notifyListeners("didEnterRegion", ret);
    }

    private void notifyDidExitRegion(Region region) {
        JSObject ret = new JSObject();
        ret.put("region", serializeRegion(region));
        notifyListeners("didExitRegion", ret);
    }

    private void notifyDidDetermineStateForRegion(int state, Region region) {
        JSObject ret = new JSObject();
        ret.put("region", serializeRegion(region));
        ret.put("state", state == org.altbeacon.beacon.MonitorNotifier.INSIDE ? "enter" : "exit");
        notifyListeners("didDetermineStateForRegion", ret);
    }

    private void notifyDidRangeBeacons(Collection<Beacon> beacons, Region region) {
        JSObject ret = new JSObject();
        ret.put("region", serializeRegion(region));
        ret.put("beacons", serializeBeacons(beacons));
        notifyListeners("didRangeBeacons", ret);
    }

    private JSObject serializeRegion(Region region) {
        JSObject obj = new JSObject();
        obj.put("identifier", region.getUniqueId());

        if (region.getId1() != null) {
            obj.put("uuid", region.getId1().toString());
        }
        if (region.getId2() != null) {
            obj.put("major", region.getId2().toInt());
        }
        if (region.getId3() != null) {
            obj.put("minor", region.getId3().toInt());
        }

        return obj;
    }

    private JSArray serializeBeacons(Collection<Beacon> beacons) {
        JSArray array = new JSArray();

        for (Beacon beacon : beacons) {
            JSObject obj = new JSObject();

            if (beacon.getId1() != null) {
                obj.put("uuid", beacon.getId1().toString());
            }
            if (beacon.getId2() != null) {
                obj.put("major", beacon.getId2().toInt());
            }
            if (beacon.getId3() != null) {
                obj.put("minor", beacon.getId3().toInt());
            }

            obj.put("rssi", beacon.getRssi());
            obj.put("accuracy", beacon.getDistance());
            obj.put("proximity", getProximity(beacon.getDistance()));

            array.put(obj);
        }

        return array;
    }

    private String getProximity(double distance) {
        if (distance < 0) {
            return "unknown";
        } else if (distance < 0.5) {
            return "immediate";
        } else if (distance < 3.0) {
            return "near";
        } else {
            return "far";
        }
    }

    /*
      All that has to happen before a scan starts: the foreground service must already be in the
      state the caller asked for, because AltBeacon refuses to change it once anything is bound.

      Binding itself is not ours any more. startMonitoring() and startRangingBeacons() autobind, and
      release the binding again when the last region stops, so there is nothing here to hold.
    */
    private void prepareToScan() {
        ensureForegroundServiceMatches(backgroundModeEnabled);
    }

    /*
      Lets go of everything once the last region is gone.

      The binding, the scan and the foreground service with its notification all exist to serve the
      two maps above, and not one of them stops when the last entry is removed - so unticking the
      final beacon left a permanent notification saying "Scanning for nearby beacons" over a scan
      with nothing left to find. Only destroying the Activity cleared it, and with a foreground
      service holding the process up that need never happen.

      The scan and its binding stop on their own once the last region does - that is what autobind
      means - so the only thing left to take down here is the foreground service, which AltBeacon has
      no reason to know is finished with. Safe when the maps were already empty:
      disableForegroundServiceIfNeeded() is idempotent, and whatever comes next calls prepareToScan().
    */
    private void releaseIfNothingLeftToWatch() {
        if (beaconManager != null && monitoredRegions.isEmpty() && rangedRegions.isEmpty()) {
            disableForegroundServiceIfNeeded();
        }
    }

    /*
      The flag drives the foreground service and nothing else now.

      It used to drive setBackgroundMode() as well, and that call is gone rather than corrected.
      AltBeacon infers foreground and background for itself from the process lifecycle - but only
      while the app has never set it by hand, since enableDefaultBackgroundStateInference() gives way
      the moment the value stops being uninitialized. Calling it was therefore switching the
      library's own inference off and replacing it with this plugin's, which watched a single
      Activity pausing rather than the process losing the foreground, and got it wrong whenever the
      two differed.
    */
    private void setBackgroundModeEnabled(boolean enabled) {
        backgroundModeEnabled = enabled;
    }

    // Covers both the first scan of a run and a later call (e.g. a per-region enableBackgroundMode
    // option) that changes the requirement while a scan is already going.
    private boolean ensureForegroundServiceMatches(boolean wantForegroundService) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || wantForegroundService == foregroundServiceEnabled) {
            return true;
        }
        return reconfigureForegroundService(wantForegroundService);
    }

    /*
      enableForegroundServiceScanning() and disableForegroundServiceScanning() throw
      IllegalStateException once anything is bound, and under autobind that means once any region is
      being watched. So the regions come down, the service changes, and they go back up - which is
      also what binds again, since stopping the last region is what released the binding in the first
      place.
    */
    private boolean reconfigureForegroundService(boolean wantForegroundService) {
        boolean wasScanning = beaconManager.isAnyConsumerBound();
        if (wasScanning) {
            stopWatchingAllRegions();
        }

        boolean success = true;
        if (wantForegroundService) {
            success = enableForegroundServiceIfNeeded();
        } else {
            disableForegroundServiceIfNeeded();
        }

        if (wasScanning) {
            startWatchingAllRegions();
        }
        return success;
    }

    private void stopWatchingAllRegions() {
        for (Region region : monitoredRegions.values()) {
            beaconManager.stopMonitoring(region);
        }
        for (Region region : rangedRegions.values()) {
            beaconManager.stopRangingBeacons(region);
        }
    }

    private void startWatchingAllRegions() {
        for (Region region : monitoredRegions.values()) {
            beaconManager.startMonitoring(region);
        }
        for (Region region : rangedRegions.values()) {
            beaconManager.startRangingBeacons(region);
        }
    }

    private boolean enableForegroundServiceIfNeeded() {
        if (foregroundServiceEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true;
        }

        try {
            // Create notification channel for foreground service
            android.app.NotificationChannel channel = new android.app.NotificationChannel(
                FOREGROUND_CHANNEL_ID,
                "Beacon Service",
                android.app.NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Background beacon monitoring service");

            android.app.NotificationManager notificationManager = getContext().getSystemService(android.app.NotificationManager.class);
            if (notificationManager != null) {
                notificationManager.createNotificationChannel(channel);
            }

            // Build notification for foreground service
            android.app.Notification.Builder builder = new android.app.Notification.Builder(getContext(), FOREGROUND_CHANNEL_ID);
            builder.setSmallIcon(android.R.drawable.ic_dialog_info);
            builder.setContentTitle("Beacon Monitoring");
            builder.setContentText("Scanning for nearby beacons");

            // Enable foreground service mode in AltBeacon
            beaconManager.enableForegroundServiceScanning(builder.build(), FOREGROUND_NOTIFICATION_ID);
            foregroundServiceEnabled = true;
            return true;
        } catch (Exception e) {
            android.util.Log.w(TAG, "Foreground service scanning unavailable, continuing without it", e);
            return false;
        }
    }

    private void disableForegroundServiceIfNeeded() {
        if (!foregroundServiceEnabled || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }

        try {
            beaconManager.disableForegroundServiceScanning();
        } catch (Exception e) {
            android.util.Log.w(TAG, "Failed to disable foreground service scanning", e);
        } finally {
            foregroundServiceEnabled = false;
        }
    }
}
