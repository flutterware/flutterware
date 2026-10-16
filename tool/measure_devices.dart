/// Measures the device table against the platforms it describes.
///
/// ```sh
/// fvm dart tool/measure_devices.dart                  # every row it can
/// fvm dart tool/measure_devices.dart --only=ipad,android-tall
/// fvm dart tool/measure_devices.dart --ios            # or --android
/// ```
///
/// Each phone and tablet in `Devices.all` is stood in for by a throwaway
/// simulator or emulator: the probe in `tool/device_probe.dart` is built once
/// per platform, run on each, and what it reads — size, ratio, safe areas in
/// portrait and on its side, the keyboard's height — is printed beside what
/// the table says. Nothing is written back: a reading that disagrees is a
/// question for whoever reads it, because an emulator is not a phone. Exits 1
/// when anything it could check disagrees.
///
/// Everything it creates is named `fwprobe-…` and deleted again, and the
/// simulator's hardware-keyboard setting is put back the way it was found.
/// It needs Xcode with an iOS runtime for the iPhones and iPads, and the
/// Android SDK with a Google Play system image — the one with Gboard — for the
/// rest. Run it after a major OS release; the insets move with the OS.
///
/// Named through fvm because the probe is built with the Flutter that runs
/// this script.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterware/devices.dart';
import 'package:path/path.dart' as p;

/// What stands in for each row: an iOS device type, or an Android emulator
/// reshaped to the row's panel with `wm size` and `wm density`.
final _standIns = <String, _StandIn>{
  'iphone-se': const _Simulator('iPhone SE (3rd generation)'),
  'iphone-13': const _Simulator('iPhone 13'),
  'iphone-16': const _Simulator('iPhone 16'),
  'iphone-16-pro': const _Simulator('iPhone 16 Pro'),
  'iphone-12-pro-max': const _Simulator('iPhone 12 Pro Max'),
  'iphone-16-plus': const _Simulator('iPhone 16 Plus'),
  'iphone-16-pro-max': const _Simulator('iPhone 16 Pro Max'),
  'ipad': const _Simulator('iPad (9th generation)'),
  'ipad-pro-13': const _Simulator('iPad Pro 13-inch (M4)'),
  // The phones are reshaped from a Pixel 8a, because a profile with a camera
  // cutout is what every phone here is — with none, a small phone's landscape
  // keyboard comes up four points taller than it does with one. But the
  // cutout is the 8a's, scaled to each density, so the status bar is the one
  // number it cannot check on these three.
  'android-small': const _Emulator(1080, 2340, 480, checksTop: false),
  'android-tall': const _Emulator(1080, 2424, 420, checksTop: false),
  'android-big': const _Emulator(1344, 2992, 480, checksTop: false),
  // And the tablets from a phone with no cutout to scale into a status bar
  // no tablet has. Not from the Pixel Tablet profile, which is landscape by
  // nature: a large screen letterboxes the probe's portrait into a 600×800
  // box, and reshaped standing it reads nothing sensible on its side. It also
  // raises a taller keyboard — 368, 320 for digits — than any phone profile
  // reshaped to the same panel, which is a question this tool cannot settle.
  'android-small-tablet': const _Emulator(
    1600,
    2560,
    320,
    profile: 'medium_phone',
  ),
  'android-medium-tablet': const _Emulator(
    2048,
    2700,
    320,
    profile: 'medium_phone',
  ),
};

Future<void> main(List<String> args) async {
  var only = {
    for (var arg in args)
      if (arg.startsWith('--only=')) ...arg.substring(7).split(','),
  };
  var wantIos = !args.contains('--android');
  var wantAndroid = !args.contains('--ios');
  var devices = [
    for (var device in Devices.all)
      if (_standIns.containsKey(device.id) &&
          (only.isEmpty || only.contains(device.id)))
        device,
  ];

  var flutter = _flutter();
  var work = await Directory.systemTemp.createTemp('fwprobe');
  var disagreements = 0;
  try {
    var app = await _createProbe(flutter, work);
    var ios = [
      for (var d in devices)
        if (_standIns[d.id] is _Simulator) d,
    ];
    var android = [
      for (var d in devices)
        if (_standIns[d.id] is _Emulator) d,
    ];
    if (wantIos && ios.isNotEmpty) {
      disagreements += await _measureIos(flutter, app, ios);
    }
    if (wantAndroid && android.isNotEmpty) {
      disagreements += await _measureAndroid(flutter, app, android);
    }
  } finally {
    await work.delete(recursive: true);
  }
  stdout.writeln(
    disagreements == 0
        ? '\nEvery reading agrees with the table.'
        : '\n$disagreements readings disagree with the table.',
  );
  exitCode = disagreements == 0 ? 0 : 1;
}

sealed class _StandIn {
  const _StandIn();
}

class _Simulator extends _StandIn {
  const _Simulator(this.type);

  /// The device type's name, as `xcrun simctl list devicetypes` spells it.
  final String type;
}

class _Emulator extends _StandIn {
  const _Emulator(
    this.width,
    this.height,
    this.density, {
    this.profile = 'pixel_8a',
    this.checksTop = true,
  });

  /// The `avdmanager` device definition the emulator is created from, before
  /// it is reshaped.
  final String profile;

  /// The panel in physical pixels, and the density that makes it the row's
  /// logical size.
  final int width;
  final int height;
  final int density;

  /// Whether the status bar can be read here — see [_standIns].
  final bool checksTop;
}

// ------------------------------------------------------------------- probe

const _bundle = 'dev.fwprobe.deviceProbe';
const _package = 'dev.fwprobe.device_probe';

/// A fresh app with the probe as its `main`, built for both platforms.
Future<Directory> _createProbe(String flutter, Directory work) async {
  stdout.writeln('Building the probe…');
  await _run(flutter, [
    'create',
    '--platforms=ios,android',
    '--org',
    'dev.fwprobe',
    '--project-name',
    'device_probe',
    'device_probe',
  ], workingDirectory: work.path);
  var app = Directory(p.join(work.path, 'device_probe'));
  var probe = p.join(
    p.dirname(Platform.script.toFilePath()),
    'device_probe.dart',
  );
  await File(probe).copy(p.join(app.path, 'lib', 'main.dart'));
  // An iPad honours `setPreferredOrientations` only for an app that opts out
  // of multitasking, and iOS reads the plist when the app is installed.
  await _run('/usr/libexec/PlistBuddy', [
    '-c',
    'Add :UIRequiresFullScreen bool true',
    p.join(app.path, 'ios', 'Runner', 'Info.plist'),
  ], allowFailure: true);
  return app;
}

/// How long one probe run may take: two keyboards thrown away and nine
/// measured, each held still for a second and a half — and on Android every
/// first focus after a launch has to be asked twice.
const _probeTimeout = Duration(minutes: 6);

/// One probe run's readings, by orientation.
typedef _Readings = Map<String, Map<String, Object?>>;

// --------------------------------------------------------------------- iOS

Future<int> _measureIos(
  String flutter,
  Directory app,
  List<Device> rows,
) async {
  if (!Platform.isMacOS) {
    stdout.writeln('\nSkipping the iOS rows: the simulators need macOS.');
    return 0;
  }
  await _run(flutter, [
    'build',
    'ios',
    '--simulator',
    '--debug',
  ], workingDirectory: app.path);
  var bundle = p.join(
    app.path,
    'build',
    'ios',
    'iphonesimulator',
    'Runner.app',
  );
  var runtime = await _latestIosRuntime();

  // The software keyboard only comes up with the hardware one disconnected.
  var keyboardDefault = await _run('defaults', [
    'read',
    'com.apple.iphonesimulator',
    'ConnectHardwareKeyboard',
  ], allowFailure: true);
  await _run('defaults', [
    'write',
    'com.apple.iphonesimulator',
    'ConnectHardwareKeyboard',
    '-bool',
    'false',
  ]);
  var disagreements = 0;
  try {
    for (var device in rows) {
      var standIn = _standIns[device.id]! as _Simulator;
      stdout.writeln('\n${device.id} — ${standIn.type}, $runtime');
      var readings = await _onSimulator(standIn.type, runtime, bundle);
      disagreements += _compare(device, readings, checksTop: true);
    }
  } finally {
    if (keyboardDefault.exitCode == 0) {
      var connected = keyboardDefault.stdout.toString().trim() == '1';
      await _run('defaults', [
        'write',
        'com.apple.iphonesimulator',
        'ConnectHardwareKeyboard',
        '-bool',
        '$connected',
      ]);
    } else {
      await _run('defaults', [
        'delete',
        'com.apple.iphonesimulator',
        'ConnectHardwareKeyboard',
      ], allowFailure: true);
    }
  }
  return disagreements;
}

Future<String> _latestIosRuntime() async {
  var listed = await _run('xcrun', ['simctl', 'list', 'runtimes', '--json']);
  var json = jsonDecode(listed.stdout as String) as Map<String, Object?>;
  var runtimes = [
    for (var runtime
        in (json['runtimes']! as List).cast<Map<String, Object?>>())
      if (runtime['isAvailable'] == true &&
          (runtime['identifier']! as String).contains('iOS'))
        runtime['identifier']! as String,
  ];
  if (runtimes.isEmpty) throw StateError('No iOS simulator runtime installed.');
  return runtimes.last;
}

Future<_Readings> _onSimulator(
  String type,
  String runtime,
  String bundle,
) async {
  var created = await _run('xcrun', [
    'simctl',
    'create',
    'fwprobe-${type.replaceAll(RegExp('[^A-Za-z0-9]+'), '-')}',
    type,
    runtime,
  ]);
  var udid = (created.stdout as String).trim();
  try {
    await _run('xcrun', ['simctl', 'boot', udid]);
    await _run('xcrun', ['simctl', 'bootstatus', udid, '-b']);
    await _run('xcrun', ['simctl', 'install', udid, bundle]);
    await _run('xcrun', ['simctl', 'launch', udid, _bundle]);
    var data = await _run('xcrun', [
      'simctl',
      'get_app_container',
      udid,
      _bundle,
      'data',
    ]);
    var result = File(
      p.join((data.stdout as String).trim(), 'tmp', 'device_probe.json'),
    );
    return await _poll(() async {
      if (!result.existsSync()) return null;
      var text = await result.readAsString();
      return text.isEmpty ? null : text;
    }, timeout: _probeTimeout);
  } finally {
    await _run('xcrun', ['simctl', 'shutdown', udid], allowFailure: true);
    await _run('xcrun', ['simctl', 'delete', udid], allowFailure: true);
  }
}

// ----------------------------------------------------------------- Android

Future<int> _measureAndroid(
  String flutter,
  Directory app,
  List<Device> rows,
) async {
  var sdk = _androidSdk();
  if (sdk == null) {
    stdout.writeln('\nSkipping the Android rows: no Android SDK found.');
    return 0;
  }
  var image = _playImage(sdk);
  if (image == null) {
    stdout.writeln(
      '\nSkipping the Android rows: no Google Play system image is installed, '
      'and the keyboard to measure is Gboard.',
    );
    return 0;
  }
  await _run(flutter, ['build', 'apk', '--debug'], workingDirectory: app.path);
  var apk = p.join(
    app.path,
    'build',
    'app',
    'outputs',
    'flutter-apk',
    'app-debug.apk',
  );

  var disagreements = 0;
  for (var profile in {
    for (var device in rows) (_standIns[device.id]! as _Emulator).profile,
  }) {
    disagreements += await _onEmulator(sdk, image, profile, apk, [
      for (var device in rows)
        if ((_standIns[device.id]! as _Emulator).profile == profile) device,
    ]);
  }
  return disagreements;
}

/// Boots a throwaway emulator from [profile], reshapes it to each of [rows] in
/// turn, and deletes it again.
Future<int> _onEmulator(
  String sdk,
  String image,
  String profile,
  String apk,
  List<Device> rows,
) async {
  var avdmanager = p.join(sdk, 'cmdline-tools', 'latest', 'bin', 'avdmanager');
  var adb = p.join(sdk, 'platform-tools', 'adb');
  var avd = 'fwprobe_$profile';
  const port = 5598;
  const serial = 'emulator-$port';
  var created = await Process.start(avdmanager, [
    'create',
    'avd',
    '-n',
    avd,
    '-k',
    image,
    '-d',
    profile,
    '--force',
  ]);
  created.stdin.writeln('no');
  await created.stdin.close();
  await created.exitCode;

  var emulator = await Process.start(p.join(sdk, 'emulator', 'emulator'), [
    '-avd',
    avd,
    '-port',
    '$port',
    '-no-window',
    '-no-audio',
    '-no-snapshot',
    '-no-boot-anim',
  ]);
  unawaited(emulator.stdout.drain<void>());
  unawaited(emulator.stderr.drain<void>());
  Future<ProcessResult> shell(List<String> command, {bool allow = false}) =>
      _run(adb, ['-s', serial, 'shell', ...command], allowFailure: allow);

  var disagreements = 0;
  try {
    stdout.writeln('\nBooting a $profile emulator on $image…');
    await _poll(() async {
      var booted = await shell(['getprop', 'sys.boot_completed'], allow: true);
      return booted.stdout.toString().trim() == '1' ? '{}' : null;
    }, timeout: const Duration(minutes: 4));
    await _run(adb, ['-s', serial, 'install', '-r', apk]);

    Future<String> log() async => (await _run(adb, [
      '-s',
      serial,
      'logcat',
      '-d',
      '-s',
      'flutter',
    ], allowFailure: true)).stdout.toString();

    /// Reshapes the emulator to [standIn]'s panel and runs the probe on it.
    Future<_Readings> probe(_Emulator standIn) async {
      await shell(['wm', 'size', '${standIn.width}x${standIn.height}']);
      await shell(['wm', 'density', '${standIn.density}']);
      await shell(['am', 'force-stop', _package]);
      await _run(adb, ['-s', serial, 'logcat', '-c']);
      await shell(['am', 'start', '-n', '$_package/.MainActivity']);
      try {
        // Read off the log, where the probe prints its line: the file it also
        // writes lands in a temporary directory `run-as` cannot name.
        return await _poll(() async {
          var line = RegExp(r'DEVICE_PROBE (\{.*\})').firstMatch(await log());
          return line?.group(1);
        }, timeout: _probeTimeout);
      } on TimeoutException {
        // What the app said is the only lead on a probe that never finished.
        stdout.writeln(await log());
        rethrow;
      }
    }

    // Once, thrown away: the first run after a boot has read a keyboard 65
    // points taller than every run after it, on the same panel.
    await probe(_standIns[rows.first.id]! as _Emulator);
    for (var device in rows) {
      var standIn = _standIns[device.id]! as _Emulator;
      stdout.writeln(
        '\n${device.id} — ${standIn.width}×${standIn.height} '
        'at ${standIn.density} dpi',
      );
      disagreements += _compare(
        device,
        await probe(standIn),
        checksTop: standIn.checksTop,
      );
    }
  } finally {
    await shell(['wm', 'size', 'reset'], allow: true);
    await shell(['wm', 'density', 'reset'], allow: true);
    await _run(adb, ['-s', serial, 'emu', 'kill'], allowFailure: true);
    await emulator.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        emulator.kill();
        return -1;
      },
    );
    await _run(avdmanager, ['delete', 'avd', '-n', avd], allowFailure: true);
  }
  return disagreements;
}

String? _androidSdk() {
  var home =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'] ??
      p.join(Platform.environment['HOME'] ?? '', 'Library', 'Android', 'sdk');
  return Directory(home).existsSync() ? home : null;
}

/// The newest installed Google Play image for this machine's architecture, as
/// `avdmanager` names it — `system-images;android-35;google_apis_playstore;
/// arm64-v8a`.
String? _playImage(String sdk) {
  var images = Directory(p.join(sdk, 'system-images'));
  if (!images.existsSync()) return null;
  var found = <(int, String)>[];
  for (var api in images.listSync().whereType<Directory>()) {
    var level = int.tryParse(p.basename(api.path).replaceFirst('android-', ''));
    var play = Directory(p.join(api.path, 'google_apis_playstore'));
    if (level == null || !play.existsSync()) continue;
    for (var abi in play.listSync().whereType<Directory>()) {
      found.add((
        level,
        'system-images;${p.basename(api.path)};google_apis_playstore;'
            '${p.basename(abi.path)}',
      ));
    }
  }
  if (found.isEmpty) return null;
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return found.last.$2;
}

// ----------------------------------------------------------------- compare

/// Prints [device]'s readings beside the table's numbers and counts the ones
/// that disagree.
int _compare(Device device, _Readings readings, {required bool checksTop}) {
  var portrait = readings['portrait']!;
  // The table's landscape is the one with the cutout on the left — on a
  // phone whose insets are symmetric either side reads the same.
  var sides = [readings['landscapeLeft']!, readings['landscapeRight']!];
  sides.sort((a, b) => _inset(b, 0).compareTo(_inset(a, 0)));
  var landscape = sides.first;
  var turned = device.rotated();

  var disagreements = 0;
  void row(String what, Object table, Object measured, {bool checked = true}) {
    var same = _same(table, measured);
    if (checked && !same) disagreements++;
    var mark = !checked ? '·' : (same ? '✓' : '✗');
    stdout.writeln(
      '  $mark ${what.padRight(20)} table ${_show(table).padRight(24)} '
      'measured ${_show(measured)}',
    );
  }

  row('size', [device.width, device.height], portrait['size']!);
  row('ratio', device.pixelRatio, portrait['ratio']!);
  row(
    'insets',
    [device.insetLeft, device.insetTop, device.insetRight, device.insetBottom],
    portrait['insets']!,
    checked: checksTop,
  );
  row('keyboard', device.keyboard, portrait['keyboard']!);
  row(
    'keypad',
    device.keyboardFor(KeyboardVariant.keypad),
    portrait['keypad']!,
    checked: _controlled(portrait),
  );
  row(
    'landscape insets',
    [turned.insetLeft, turned.insetTop, turned.insetRight, turned.insetBottom],
    landscape['insets']!,
    checked: checksTop,
  );
  row('landscape keyboard', turned.keyboard, landscape['keyboard']!);
  row(
    'landscape keypad',
    turned.keyboardFor(KeyboardVariant.keypad),
    landscape['keypad']!,
    checked: _controlled(landscape),
  );
  for (var (name, reading) in [
    ('portrait', portrait),
    ('landscape', landscape),
  ]) {
    if (!_controlled(reading)) {
      stdout.writeln(
        '  · the $name keypad failed its control: letters read '
        '${_show(reading['keyboard']!)} before it and '
        '${_show(reading['control']!)} after',
      );
    }
  }
  if (!checksTop) {
    stdout.writeln(
      "  · the insets are the panel author's: this emulator draws no cutout",
    );
  }
  var cutouts = portrait['cutouts']! as List;
  if (cutouts.isNotEmpty) stdout.writeln('  · cutouts ${_show(cutouts)}');
  return disagreements;
}

/// Whether the letters keyboard read the same before the keypad and after it
/// — what makes the keypad reading between them one to believe.
bool _controlled(Map<String, Object?> reading) =>
    _same(reading['keyboard']!, reading['control']!);

double _inset(Map<String, Object?> reading, int side) =>
    ((reading['insets']! as List)[side] as num).toDouble();

/// Whether two readings agree to the platform's own rounding: a hundredth of
/// a point, which is what a physical pixel over a fractional ratio leaves.
bool _same(Object a, Object b) => switch ((a, b)) {
  (num x, num y) => (x - y).abs() < 0.06,
  (List x, List y) =>
    x.length == y.length &&
        [
          for (var i = 0; i < x.length; i++)
            _same(x[i] as Object, y[i] as Object),
        ].every((same) => same),
  _ => a == b,
};

String _show(Object value) => switch (value) {
  num n => n == n.roundToDouble() ? '${n.round()}' : n.toStringAsFixed(2),
  List list => '[${list.map((v) => _show(v as Object)).join(', ')}]',
  _ => '$value',
};

// ---------------------------------------------------------------- plumbing

/// The Flutter SDK above [Platform.resolvedExecutable] — the one that runs
/// this script, and never one found on `PATH`.
String _flutter() {
  var dir = p.dirname(Platform.resolvedExecutable);
  while (true) {
    var flutter = p.join(dir, 'bin', 'flutter');
    if (File(flutter).existsSync() &&
        File(p.join(dir, 'bin', 'cache', 'flutter.version.json'))
            .existsSync()) {
      return flutter;
    }
    var parent = p.dirname(dir);
    if (parent == dir) {
      throw StateError(
        "Not run by a Flutter SDK's dart. Run it as "
        '`fvm dart tool/measure_devices.dart`.',
      );
    }
    dir = parent;
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> args, {
  String? workingDirectory,
  bool allowFailure = false,
}) async {
  var result = await Process.run(
    executable,
    args,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0 && !allowFailure) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}\n${result.stderr}'.trim(),
      result.exitCode,
    );
  }
  return result;
}

/// Asks [read] until it answers JSON, for up to [timeout].
Future<_Readings> _poll(
  Future<String?> Function() read, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  var deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    var text = await read();
    if (text != null) {
      return {
        for (var MapEntry(:key, :value)
            in (jsonDecode(text) as Map<String, Object?>).entries)
          key: (value! as Map).cast<String, Object?>(),
      };
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException('No reading', timeout);
}
