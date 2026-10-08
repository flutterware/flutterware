import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../device/adb_settings.dart';
import '../device/device_settings.dart';
import '../device/simctl_settings.dart';
import '../handle.dart';
import 'adb_driver.dart';
import 'ax_driver.dart';
import 'native_driver.dart';
import 'native_logs.dart';

/// One native transaction, and the driver it runs on.
///
/// The shape is the drive layer's, deliberately: resolve against a *fresh*
/// tree, act, look again, answer with one bundle describing one moment. An
/// agent that has been tapping widgets all session should find nothing new
/// here except which tree it is addressing.
///
/// Held per run like [DriveSession], for the same reason and one more: the
/// driver learns things (Android's package, the simulator's window) that a
/// per-call driver would keep rediscovering.
class NativeSession {
  NativeSession(this.handle);

  final RunHandle handle;

  NativeDriver? _driver;
  Future<NativeDriver?>? _resolving;

  /// The driver for this run's device, or null when this machine has none.
  ///
  /// Cached including the null: asking `adb devices` on every act to be told
  /// again that a macOS run is not an Android device is a round trip that can
  /// only have one answer.
  Future<NativeDriver?> driver() {
    if (_resolving case var held?) return held;
    return _resolving = _resolve();
  }

  /// Whether this device *could* be driven natively, without building
  /// anything to find out.
  ///
  /// Split from [driver] because of where it is asked: a drive-layer refusal
  /// mentions the native layer only if there is one, and that question must
  /// not cost the caller a Swift compile. Identity is cheap to establish;
  /// the helper is built when the layer is actually asked for.
  /// Set by tests, so the drive path can be exercised without a device.
  bool? debugAvailable;

  Future<bool> get isAvailable async {
    if (debugAvailable case var forced?) return forced;
    if (_available case var known?) return known;
    var adb = AdbNativeDriver.findAdb();
    if (adb != null && await AdbNativeDriver.owns(handle.device, adb)) {
      return _available = true;
    }
    if (!Platform.isMacOS) return _available = false;
    if (handle.device == 'macos') {
      return _available = await macosBundle() != null;
    }
    return _available = await _bootedSimulator(handle.device) != null;
  }

  bool? _available;

  /// This run's platform log, or null when this machine cannot read one.
  ///
  /// Held here because it is the same identity question [driver] answers —
  /// which device is this, really — and the answers are the same three:
  /// `adb` owns the serial, it is a booted simulator, or it is a macOS bundle.
  /// It costs no Swift compile, unlike [driver]: reading a log needs the
  /// device's name, not the accessibility helper.
  ///
  /// A physical iOS device is deliberately not one of them. Its log comes off
  /// `devicectl` or `idevicesyslog` rather than the host's own store, which is
  /// a third mechanism rather than a fourth argument, and half-working here
  /// would be worse than refusing with the command.
  Future<NativeLogSource?> logSource() {
    if (_resolvingLog case var held?) return held;
    return _resolvingLog = _resolveLogSource();
  }

  Future<NativeLogSource?>? _resolvingLog;

  Future<NativeLogSource?> _resolveLogSource() async {
    var adb = AdbNativeDriver.findAdb();
    if (adb != null && await AdbNativeDriver.owns(handle.device, adb)) {
      return AndroidLogSource(serial: handle.device, adb: adb);
    }
    if (!Platform.isMacOS) return null;
    if (handle.device == 'macos') {
      var bundle = await macosBundle();
      return bundle == null ? null : AppleLogSource.macos(bundle: bundle);
    }
    if (await _bootedSimulator(handle.device) != null) {
      return AppleLogSource.simulator(udid: handle.device);
    }
    return null;
  }

  /// This device's settings, or null when this machine has no way to write
  /// them.
  ///
  /// The same identity question [driver] answers, with the same three answers
  /// and the same caching-including-the-null — but a different object, because
  /// setting a device and driving one are different concerns with different
  /// platform matrices. See `DeviceSettings`' own doc comment for why they are
  /// not one interface.
  ///
  /// Costs no Swift compile: `simctl` and `adb` are both already there, which
  /// is the other reason this does not ride the driver.
  Future<DeviceSettings?> settings() {
    if (_resolvingSettings case var held?) return held;
    return _resolvingSettings = _resolveSettings();
  }

  Future<DeviceSettings?>? _resolvingSettings;

  Future<DeviceSettings?> _resolveSettings() async {
    var adb = AdbNativeDriver.findAdb();
    if (adb != null && await AdbNativeDriver.owns(handle.device, adb)) {
      return AdbDeviceSettings(serial: handle.device, adb: adb);
    }
    if (!Platform.isMacOS) return null;
    if (await _bootedSimulator(handle.device) != null) {
      return SimctlDeviceSettings(udid: handle.device);
    }
    // macOS, web and a physical iPhone all land here. Each has settings a host
    // can write — measured — and none of them shipped in v1, so the honest
    // answer for now is that this session has no backend rather than a
    // half-built one.
    return null;
  }

  Future<NativeDriver?> _resolve() async {
    var adb = AdbNativeDriver.findAdb();
    if (adb != null && await AdbNativeDriver.owns(handle.device, adb)) {
      return _driver = AdbNativeDriver(serial: handle.device, adb: adb);
    }
    if (!Platform.isMacOS) return null;

    // The two Apple targets are one mechanism pointed at two processes: the
    // simulator is a Mac app whose accessibility tree contains the whole
    // simulated device, and a macOS run is that same API on the app's own pid.
    var simulator = await _bootedSimulator(handle.device);
    var helper = await AxNativeDriver.ensureHelper();
    if (helper == null) return null;
    if (simulator != null) {
      return _driver = AxNativeDriver(
        platform: 'ios-simulator',
        helper: helper,
        app: 'com.apple.iphonesimulator',
        // Scoped to this device's window: a Mac can run several simulators,
        // and an unscoped walk would also drag in the host's menu bar.
        window: simulator,
      )..simulatorUdid = handle.device;
    }
    if (handle.device == 'macos') {
      var bundle = await macosBundle();
      if (bundle == null) return null;
      return _driver = AxNativeDriver(
        platform: 'macos',
        helper: helper,
        app: bundle,
      );
    }
    return null;
  }

  /// The window title of [device] if it is a booted simulator, else null.
  ///
  /// `simctl list` rather than the shape of the id: a UDID is only a UUID, and
  /// guessing from its shape would mistake any other UUID-shaped device id for
  /// a simulator.
  Future<String?> _bootedSimulator(String device) async {
    try {
      var result = await Process.run('xcrun', [
        'simctl',
        'list',
        'devices',
        'booted',
        '-j',
      ]);
      if (result.exitCode != 0) return null;
      if (jsonDecode('${result.stdout}') case {'devices': Map runtimes}) {
        for (var runtime in runtimes.values) {
          for (var entry in (runtime as List).cast<Map<String, Object?>>()) {
            if (entry['udid'] == device) return entry['name'] as String?;
          }
        }
      }
    } on Object {
      // No Xcode, or a `simctl` that answered something else. Either way this
      // machine has no simulator to drive.
    }
    return null;
  }

  /// The bundle this run launched, as a path.
  ///
  /// A path rather than a product name, and the difference is a bug this found
  /// the moment it ran: two worktrees building the same package produce two
  /// running apps with the same name, and picking by name attached the driver
  /// to the wrong window. It is the machine-global selection hole the
  /// drive layer already closed with `ownHandles`, met again one layer down —
  /// and the same answer applies, that only this checkout's run is a drivable
  /// subject. The build directory under this worktree is what makes it this
  /// checkout's.
  ///
  /// Which build directory, though, is not the build's to choose. Xcode
  /// keeps one directory per configuration under `Products`, and a checkout
  /// that has ever been released keeps `Release` next to `Debug` forever. The
  /// first version of this walked those directories and took the first `.app`
  /// it met, which is filesystem order — so a worktree holding both handed the
  /// helper a Release bundle nothing was running from, and the layer refused
  /// with `notFound` on the debug inner loop it exists to serve.
  ///
  /// So ask the process table first: the run is up, its executable path is in
  /// there, and that path *is* the answer rather than a guess at one. The
  /// scope that makes it this checkout's run is unchanged — a process only
  /// counts if it is executing from under this worktree's build directory.
  ///
  /// [executables] stands in for the process table under test.
  @visibleForTesting
  Future<String?> macosBundle({List<String>? executables}) async {
    var package = handle.package;
    if (package == null) return null;
    var products = p.join(
      handle.worktree,
      package,
      'build',
      'macos',
      'Build',
      'Products',
    );
    var running = runningBundleUnder(
      products,
      executables ?? await _executables(),
    );
    if (running != null) return running;

    // Nothing is executing from here — still building, or already stopped. The
    // build directory is all there is to answer from, and the configuration
    // the run *would* use is the one to name: `flutter run` is debug, and a
    // flavor makes that `Debug-<flavor>`. Naming it keeps the helper's refusal
    // honest ("rebuilt since, or stopped") instead of pointing it at a Release
    // bundle and blaming the wrong thing.
    var build = Directory(products);
    if (!build.existsSync()) return null;
    var configuration = preferredConfiguration(
      build.listSync().whereType<Directory>().map((d) => p.basename(d.path)),
      flavor: handle.flavor,
    );
    if (configuration == null) return null;
    var bundles =
        Directory(p.join(products, configuration))
            .listSync()
            .map((e) => e.path)
            .where((path) => path.endsWith('.app'))
            .toList()
          ..sort();
    return bundles.isEmpty ? null : bundles.first;
  }

  /// Every running executable's path, from the process table.
  ///
  /// `comm=` rather than a bundle id or a name: the whole point is to learn
  /// *where* a process is executing from, and the path is the only field that
  /// separates two worktrees running the same app.
  Future<List<String>> _executables() async {
    try {
      var result = await Process.run('ps', ['-Ao', 'comm=']);
      if (result.exitCode != 0) return const [];
      return LineSplitter.split('${result.stdout}')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
    } on Object {
      return const [];
    }
  }

  /// The `.app` under [products] that one of [executables] is running from.
  ///
  /// Split out to be tested against a real process table's worth of lines,
  /// because the failure it fixes is one a live app cannot be relied on to
  /// reproduce: it needs a worktree that happens to hold two configurations.
  @visibleForTesting
  static String? runningBundleUnder(
    String products,
    Iterable<String> executables,
  ) {
    var root = p.canonicalize(products);
    for (var executable in executables) {
      if (!p.isWithin(root, p.canonicalize(executable))) continue;
      // …/Debug/app.app/Contents/MacOS/app → …/Debug/app.app. Walked up rather
      // than assumed, so a bundle nested any other way still resolves.
      for (var dir = p.dirname(executable); ; dir = p.dirname(dir)) {
        if (dir.endsWith('.app')) return dir;
        var parent = p.dirname(dir);
        if (parent == dir || !p.isWithin(root, p.canonicalize(dir))) break;
      }
    }
    return null;
  }

  /// The configuration directory a launch from this plugin would write into.
  ///
  /// `flutter run` builds debug and takes no mode flag here (see
  /// `launchRun`), so Debug is the answer — `Debug-<flavor>` when the run has
  /// a flavor, which is what Xcode names a flavored scheme's configuration.
  @visibleForTesting
  static String? preferredConfiguration(
    Iterable<String> names, {
    String? flavor,
  }) {
    var all = names.toList()..sort();
    var wanted = flavor == null ? null : 'debug-${flavor.toLowerCase()}';
    for (var test in <bool Function(String)>[
      if (wanted != null) (name) => name == wanted,
      (name) => name == 'debug',
      (name) => name.startsWith('debug'),
    ]) {
      for (var name in all) {
        if (test(name.toLowerCase())) return name;
      }
    }
    return null;
  }

  /// Why this device has no native layer, written for the agent that just
  /// asked for one.
  ///
  /// Says which platforms *do* have one, because the useful next thought is
  /// usually "then run it somewhere that does" — and says the drive layer is
  /// still there, because on a desktop run it answers almost everything the
  /// native layer would have.
  String get unavailable =>
      'The native layer has no driver for ${handle.deviceLabel}. It drives '
      'Android devices and emulators through adb, and the iOS simulator and '
      'macOS through the accessibility helper. Everything Flutter draws can '
      'be reached without it: drop `layer` to use the widget tree.';

  /// Resolve → act → observe, as one reply.
  ///
  /// [verb] is the native vocabulary, deliberately smaller than the drive
  /// layer's: what a platform tree cannot do — walk a lazy list to something
  /// not yet built — is refused rather than approximated.
  Future<NativeStep> act({
    required String verb,
    String? target,
    String? text,
    bool screenshot = true,
  }) async {
    var driver = await this.driver();
    if (driver == null) {
      throw NativeRefusal(unavailable, failure: 'unavailable');
    }
    var started = DateTime.now();

    String? described;
    if (verb != 'observe' && verb != 'foreground') {
      var spec = target;
      if (spec == null) {
        throw NativeRefusal(
          '`$verb` needs a target. On the native layer that is bare visible '
          'text, {"containing": …}, {"role": …}, or {"at": {"x": …, "y": …}} '
          'for a point the platform publishes no element for.',
          failure: 'notFound',
        );
      }
      // Resolved against a tree read *now*: the screen may have moved since
      // whatever the agent read, and a stale match is exactly the wrong-target
      // tap this layer refuses to make.
      var before = await driver.observe(screenshot: false);
      var parsed = NativeTarget.parse(spec);
      described = parsed.description;
      switch (verb) {
        case 'tap':
          if (parsed.point case (var x, var y)) {
            await driver.tapAt(x, y);
          } else {
            await driver.tapNode(parsed.resolve(before));
          }
        case 'enterText':
          if (text == null) {
            throw NativeRefusal(
              '`enterText` needs `text` to type.',
              failure: 'notFound',
            );
          }
          // Focus first, the way a person would: native text entry types into
          // whatever holds focus, and nothing else on this layer knows what
          // that is.
          if (parsed.point case (var x, var y)) {
            await driver.tapAt(x, y);
          } else {
            await driver.tapNode(parsed.resolve(before));
          }
          await driver.enterText(text);
        default:
          throw NativeRefusal(
            '`$verb` is not a native verb. The native layer does `observe`, '
            '`tap`, `enterText` and `foreground`. Everything else (doubleTap, '
            'secondaryTap, drag, scroll, scrollTo, hover, key, back, navigate) '
            "belongs to the drive layer, which addresses Flutter's own tree. "
            'Drop `layer` for those.',
            failure: 'unsupported',
          );
      }
    } else if (verb == 'foreground') {
      await driver.foreground();
      // The OS needs a moment to actually swap the app in; without it the
      // observation photographs the screen we came from.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }

    var observation = await driver.observe(screenshot: screenshot);
    return NativeStep(
      verb: verb,
      target: described,
      observation: observation,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  Future<void> close() async {
    await _driver?.close();
    _driver = null;
    _resolving = null;
  }
}

/// What one native transaction produced.
class NativeStep {
  NativeStep({
    required this.verb,
    required this.observation,
    required this.elapsedMs,
    this.target,
  });

  final String verb;

  /// The target as the resolver described it — the drive layer's spelling, so
  /// the journal reads the same whichever layer wrote the line.
  final String? target;

  final NativeObservation observation;
  final int elapsedMs;
}
