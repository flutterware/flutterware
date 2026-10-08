import 'dart:io';

import 'package:meta/meta.dart';
import 'package:xml/xml.dart';

import 'native_driver.dart';

/// Android's native layer, over plain `adb`.
///
/// No on-device agent, no extra dependency: `uiautomator dump` and `input` are
/// on every Android image, and `adb` is in the SDK every Flutter Android build
/// already needs. The Patrol-style automator APK — the heavier mechanism this
/// could have been — stays unbuilt because the cheap path passed its spike:
/// ~2.5s per dump idle, ~4s under a continuous animation, twelve dumps and no
/// failures, taps landing on the first try.
///
/// Two measured facts shape everything here. **The dump arms Flutter's
/// semantics by itself** — UiAutomation registers as an accessibility service,
/// Flutter's `AccessibilityBridge` publishes, and the tree that comes back is
/// Flutter content *merged* with native views, without the guest being asked
/// anything. And **the dump, `input tap` and `screencap` all speak physical
/// pixels**, so there is no coordinate mapping in this file and none is
/// missing.
///
/// This driver also works against a physical Android device, unchanged: `adb`
/// does not care, and neither does anything below.
class AdbNativeDriver extends NativeDriver {
  AdbNativeDriver({required this.serial, required this.adb});

  /// The device as `adb -s` takes it — which is the same string `flutter run
  /// -d` takes, so [RunHandle.device] is the serial with no translation.
  final String serial;

  /// Absolute path to `adb`.
  final String adb;

  /// The app's package, learned from a dump that saw it.
  ///
  /// Only [foreground] needs it, and only Android's rarest case needs
  /// [foreground] at all — a backgrounded Android app drives fine (measured;
  /// it is iOS that suspends). So this is learned rather than configured: any
  /// observation that finds the app on screen records its package, and the one
  /// verb that needs it says plainly when nothing has.
  String? _package;

  @override
  String get platform => 'android';

  /// Physical pixels, for bounds, taps and the screenshot alike. The one
  /// platform where nothing has to be converted.
  @override
  String get coordinateSpace => 'px';

  /// Where `adb` is, or null if this machine has no Android SDK.
  ///
  /// Located the way `flutter` locates it — from the SDK — rather than from
  /// `PATH`, because a working Android toolchain routinely has it in neither
  /// `PATH` nor a shell profile the GUI would inherit. (The dev machine this
  /// was built on is exactly that case: `adb` installed, `which adb` empty.)
  static String? findAdb({Map<String, String>? environment}) {
    var env = environment ?? Platform.environment;
    var roots = <String>[
      if (env['ANDROID_HOME'] case var home? when home.isNotEmpty) home,
      if (env['ANDROID_SDK_ROOT'] case var root? when root.isNotEmpty) root,
      if (env['HOME'] case var home? when home.isNotEmpty) ...[
        '$home/Library/Android/sdk',
        '$home/Android/Sdk',
      ],
      if (env['LOCALAPPDATA'] case var local? when local.isNotEmpty)
        '$local\\Android\\Sdk',
    ];
    for (var root in roots) {
      var candidate = Platform.isWindows
          ? '$root\\platform-tools\\adb.exe'
          : '$root/platform-tools/adb';
      if (File(candidate).existsSync()) return candidate;
    }
    // A PATH `adb` is still worth taking when the SDK is somewhere unusual;
    // it is just not what we look at first.
    var which = Platform.isWindows ? 'where' : 'which';
    try {
      var result = Process.runSync(which, ['adb']);
      if (result.exitCode == 0) {
        var path = (result.stdout as String).split('\n').first.trim();
        if (path.isNotEmpty && File(path).existsSync()) return path;
      }
    } on ProcessException {
      // No `which` either. Answering "no adb" is the honest result.
    }
    return null;
  }

  /// Whether [device] is an Android device this driver can drive — asked of
  /// `adb` rather than guessed from the shape of the id, because a physical
  /// serial looks like nothing in particular.
  static Future<bool> owns(String device, String adb) async {
    try {
      var result = await Process.run(adb, ['devices']);
      for (var line in (result.stdout as String).split('\n').skip(1)) {
        var parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 &&
            parts.first == device &&
            parts[1] == 'device') {
          return true;
        }
      }
    } on ProcessException {
      return false;
    }
    return false;
  }

  Future<ProcessResult> _adb(
    List<String> args, {
    bool binaryOutput = false,
  }) async {
    var result = await Process.run(adb, [
      '-s',
      serial,
      ...args,
    ], stdoutEncoding: binaryOutput ? null : systemEncoding);
    if (result.exitCode != 0) {
      throw NativeRefusal(
        'adb ${args.join(' ')} failed on $serial: '
        '${'${result.stderr}'.trim()}',
        failure: 'unavailable',
      );
    }
    return result;
  }

  @override
  Future<NativeObservation> observe({bool screenshot = true}) async {
    // Dump to a file, then cat it, rather than `exec-out uiautomator dump
    // /dev/tty`: the direct form mixes uiautomator's own chatter into the
    // stream on some images, and two round trips of a 12KB file cost
    // milliseconds against a dump that costs seconds.
    const remote = '/sdcard/flutterware_ui_dump.xml';
    var xml = await _dump(remote);

    List<int>? png;
    if (screenshot) {
      var shot = await _adb([
        'exec-out',
        'screencap',
        '-p',
      ], binaryOutput: true);
      png = shot.stdout as List<int>;
    }

    var root = _parse(xml);
    return NativeObservation(
      platform: platform,
      coordinateSpace: coordinateSpace,
      root: root,
      screenshot: png,
      // The dump, the taps and the picture are one space on Android. Said out
      // loud anyway: an agent should never have to infer that a scale is 1.
      screenshotScale: 1,
      note: _focusedWindowRule,
    );
  }

  /// The limit worth knowing before it bites.
  ///
  /// `uiautomator dump` describes the **focused** window, not the screen.
  /// Anything that takes focus is therefore fully addressable — a permission
  /// dialog, a system alert, another app entirely (measured: launching
  /// Settings over the app made the dump Settings). The soft keyboard is the
  /// one common thing that does not take focus, so its keys are absent from
  /// this tree even while it is plainly up in the screenshot.
  ///
  /// Stated on every observation rather than only when a keyboard is present,
  /// because the confusing case is exactly the one where an agent is looking
  /// for something and cannot tell "not on screen" from "not in this window".
  static const _focusedWindowRule =
      'This tree is the focused window. Dialogs, system alerts and other apps '
      'take focus and appear here in full; the soft keyboard does not take '
      'focus, so its keys are missing even when the screenshot shows it. Type '
      'with the drive layer (drop `layer` and use enterText) rather than by '
      'pressing keys.';

  /// The dump, retried once through the gap between two windows.
  ///
  /// `uiautomator` answers `ERROR: null root node returned by
  /// UiTestAutomationBridge` while a window is being replaced — measured, one
  /// second after launching another activity over the app. It is a moment, not
  /// a state, and the second attempt has always found the new window; retrying
  /// is what keeps "observe right after tapping something that opens a dialog"
  /// from being a coin flip.
  Future<String> _dump(String remote) async {
    for (var attempt = 0; ; attempt++) {
      var result = await Process.run(adb, [
        '-s',
        serial,
        'shell',
        'uiautomator',
        'dump',
        remote,
      ]);
      var output = '${result.stdout}${result.stderr}';
      if (result.exitCode == 0 && !output.contains('ERROR')) {
        return (await _adb(['exec-out', 'cat', remote])).stdout as String;
      }
      if (attempt == 1) {
        throw NativeRefusal(
          'The device would not describe its screen: ${output.trim()}. This '
          'usually means a window is still opening; try again.',
          failure: 'unavailable',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  /// The dump parser, without a device — the seam the tree tests run against.
  ///
  /// Parsing is where this driver's judgement lives (what counts as a label,
  /// which wrappers collapse, what is addressable), and none of it needs an
  /// emulator to be wrong.
  @visibleForTesting
  static NativeObservation debugParse(String xml) {
    var driver = AdbNativeDriver(serial: 'test', adb: 'adb');
    return NativeObservation(
      platform: driver.platform,
      coordinateSpace: driver.coordinateSpace,
      root: driver._parse(xml),
      screenshotScale: 1,
    );
  }

  NativeNode _parse(String xml) {
    var document = XmlDocument.parse(xml);
    var hierarchy = document.rootElement;
    var children = [
      for (var element in hierarchy.childElements) _node(element),
    ];
    return NativeNode(
      role: 'hierarchy',
      children: [for (var child in children) ?child],
    );
  }

  NativeNode? _node(XmlElement element) {
    var text = element.getAttribute('text') ?? '';
    var description = element.getAttribute('content-desc') ?? '';
    var role = element.getAttribute('class') ?? 'node';
    var package = element.getAttribute('package');
    // The app's own package, learned in passing — see [_package].
    if (package != null &&
        !package.startsWith('com.android.') &&
        !package.startsWith('com.google.android.') &&
        package != 'android') {
      _package ??= package;
    }

    var children = <NativeNode>[
      for (var child in element.childElements) ?_node(child),
    ];

    var label = text.isNotEmpty
        ? text
        : description.isNotEmpty
        ? description
        : null;
    var clickable = element.getAttribute('clickable') == 'true';
    var node = NativeNode(
      role: role,
      label: label,
      bounds: _bounds(element.getAttribute('bounds')),
      clickable: clickable,
      enabled: element.getAttribute('enabled') != 'false',
      focused: element.getAttribute('focused') == 'true',
      checked: element.getAttribute('checkable') == 'true'
          ? element.getAttribute('checked') == 'true'
          : null,
      children: children,
    );

    // Collapse the layout chains Android publishes between anything two
    // people would call elements: a `FrameLayout` wrapping a `LinearLayout`
    // wrapping the one view that says something is three nodes describing one
    // thing.
    //
    // Only *generic containers* collapse, and the distinction is load-bearing
    // rather than fussy: a `WebView` with one child is also a silent wrapper
    // by these rules, and collapsing it would delete the one word telling an
    // agent why the Flutter layer could not see this — that it is a platform
    // view. What a node *is* survives; what it merely *wraps* does not.
    if (label == null &&
        !clickable &&
        children.length == 1 &&
        _isGenericContainer(role)) {
      return children.single;
    }
    return node;
  }

  static bool _isGenericContainer(String role) {
    if (role.endsWith('Layout')) return true;
    return const {
      'android.view.View',
      'android.view.ViewGroup',
      'androidx.compose.ui.platform.ComposeView',
    }.contains(role);
  }

  static final _boundsPattern = RegExp(
    r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]',
  );

  static NativeBounds? _bounds(String? raw) {
    if (raw == null) return null;
    var match = _boundsPattern.firstMatch(raw);
    if (match == null) return null;
    return NativeBounds(
      double.parse(match.group(1)!),
      double.parse(match.group(2)!),
      double.parse(match.group(3)!),
      double.parse(match.group(4)!),
    );
  }

  @override
  Future<void> tapNode(NativeNode node) async {
    var bounds = node.bounds;
    if (bounds == null) {
      throw NativeRefusal(
        '${node.describe()} published no bounds, so there is nowhere to tap '
        'it. Target something else, or use {"at": {"x": …, "y": …}}.',
        failure: 'notFound',
      );
    }
    await tapAt(bounds.centerX, bounds.centerY);
  }

  @override
  Future<void> tapAt(double x, double y) async {
    await _adb(['shell', 'input', 'tap', '${x.round()}', '${y.round()}']);
  }

  @override
  Future<void> enterText(String text) async {
    // `input text` runs through the device's shell, so the argument is quoted
    // for *that* shell, and spaces go as `%s` — the escape `input` itself
    // understands. Slow (measured 6.5s for fourteen characters, key by key)
    // and ASCII-shaped, which is why the drive layer's `enterText` stays the
    // text path wherever it reaches.
    var escaped = text.replaceAll("'", r"'\''").replaceAll(' ', '%s');
    await _adb(['shell', 'input', 'text', "'$escaped'"]);
  }

  @override
  Future<void> foreground() async {
    var package = _package;
    if (package == null) {
      throw NativeRefusal(
        'This driver has not seen the app on screen yet, so it does not know '
        'which package to bring forward. `observe` once while it is visible '
        'and retry. Android rarely needs this: a backgrounded Android app '
        'still answers the drive layer.',
        failure: 'unavailable',
      );
    }
    // The launcher intent resumes the existing task rather than starting a
    // new one, which is the whole point: `foreground` must not cost the app
    // its state.
    await _adb([
      'shell',
      'monkey',
      '-p',
      package,
      '-c',
      'android.intent.category.LAUNCHER',
      '1',
    ]);
  }
}
