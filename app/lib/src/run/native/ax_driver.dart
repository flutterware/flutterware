import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../constants.dart';
import '../../utils/run_dir.dart';
import 'native_driver.dart';

/// The native layer on Apple platforms, through macOS accessibility.
///
/// One driver for two targets, because they are one mechanism: the iOS
/// simulator is a Mac application whose accessibility tree contains the whole
/// simulated device — every element of the app under test, the home screen,
/// the keyboard, system dialogs — and a macOS app is the same API pointed at a
/// different pid.
///
/// Scope differs sharply between the two, and the tool reports which. On the
/// simulator this reads the app under test: measured, the complete Flutter
/// screen with labels and frames, no guest and no semantics handshake. On
/// macOS the brief is *native chrome* — menus, dialogs, save panels, other
/// apps — and a Flutter app's own widgets usually do not appear.
///
/// Usually, not never — the first version of this comment said never, and
/// it was wrong. The framework says the rule itself when asked for a
/// semantics tree it has not built: *"the framework only generates semantics
/// when asked to do so by the platform"*. Flutterware's own
/// `ensureSemantics()` is framework-side and does **not** ask the platform, so
/// nothing we do turns publication on — which is why the macOS brief holds in
/// practice. But the platform can be asked from outside (an assistive client
/// attaching, VoiceOver, an `AXEnhancedUserInterface` probe), and an app in
/// that state publishes its whole Flutter tree here: observed on this very
/// example app, ten labels deep, and on exactly one of two identical Brewline
/// builds — which is what made it look like a property of the app rather than
/// of the process.
///
/// Not turned into a feature, deliberately: the same app, given the same
/// treatment, published in one run and refused in the next, so there is no
/// reliable recipe to put behind a verb. The risk of leaving it is
/// one-directional — an agent either sees the chrome it came for, or that
/// plus Flutter content it can also use.
///
/// Found by `app/tool/native_spike/semantics_state.dart`, which reads whether
/// the *platform* has asked, without changing the answer.
class AxNativeDriver extends NativeDriver {
  AxNativeDriver({
    required this.platform,
    required this.helper,
    required this.app,
    this.window,
  });

  @override
  final String platform;

  /// The compiled helper binary.
  final String helper;

  /// Bundle id or application name the helper attaches to.
  final String app;

  /// Which window to scope the walk to, by title prefix — the simulator's
  /// device window. Null means every window of the app.
  final String? window;

  /// Window points, which is what the accessibility API reports and what
  /// synthetic clicks consume. Not screenshot pixels: a retina screenshot is
  /// twice this, and [NativeObservation.screenshotScale] carries the factor
  /// rather than leaving an agent to discover it by missing.
  @override
  String get coordinateSpace => 'points';

  double? _scale;

  /// The last tree, kept so a target resolved against it can be pressed by the
  /// path it was found at. Re-verified inside the helper before it acts.
  Map<NativeNode, String> _paths = {};

  Future<Map<String, Object?>> _run(Map<String, Object?> command) async {
    var result = await Process.run(helper, [
      jsonEncode({
        'app': app,
        if (window != null) 'window': window,
        // The simulated display only, so the Simulator's own bezel and
        // toolbar do not read as part of the app being driven.
        if (window != null) 'scope': 'device',
        ...command,
      }),
    ]);
    Map<String, Object?>? reply;
    var out = '${result.stdout}'.trim();
    if (out.isNotEmpty) {
      try {
        reply = jsonDecode(out.split('\n').last) as Map<String, Object?>;
      } on FormatException {
        // Fall through to the raw-output error below: a helper that printed
        // something unparseable is more usefully reported verbatim.
      }
    }
    if (reply == null) {
      throw NativeRefusal(
        'The accessibility helper said nothing usable: '
        '${out.isEmpty ? '${result.stderr}'.trim() : out}',
        failure: 'unavailable',
      );
    }
    if (reply['ok'] != true) {
      var code = reply['code'] as String?;
      var message = code == 'untrusted' ? _untrusted : '${reply['error']}';
      if (simulatorUdid != null) {
        message = switch (code) {
          'noApp' =>
            '$message: Simulator is not running, so this device has no window '
                'for the native layer to read — and an app on it sits '
                '`inactive`, drawing nothing. `act {verb: foreground, layer: '
                'native}` opens it.',
          'noWindow' =>
            '$message\nThe device is booted without a window, so the native '
                'layer has nothing to read. `act {verb: foreground, layer: '
                'native}` opens one.',
          _ => message,
        };
      }
      throw _HelperRefusal(
        message,
        code: code,
        said: '${reply['error']}',
        failure: switch (code) {
          'stale' || 'noWindow' || 'noApp' || 'noMenu' => 'notFound',
          'notPressable' => 'unsupported',
          _ => 'unavailable',
        },
      );
    }
    return reply;
  }

  /// What to report when the helper cannot see anything.
  ///
  /// Names the app the grant actually belongs to rather than the helper: macOS
  /// attaches accessibility permission to the *responsible* process — whatever
  /// spawned this — so "flutterware" or the user's terminal is what appears in
  /// System Settings, and pointing at `ax_helper` would send the reader hunting
  /// for a row that does not exist.
  static String get _untrusted {
    var owner = Platform.environment['TERM_PROGRAM'] ?? 'the app running this';
    return 'macOS has not granted accessibility permission, so the native '
        'layer cannot see or touch anything. Grant it in System Settings › '
        'Privacy & Security › Accessibility — the entry to enable is $owner '
        '(the permission belongs to the program that started flutterware, not '
        'to a helper of its own). Then retry; nothing needs restarting but '
        'the granted app.';
  }

  @override
  Future<NativeObservation> observe({bool screenshot = true}) async {
    var reply = await _run({'cmd': 'observe'});
    _scale = (reply['scale'] as num?)?.toDouble();
    _paths = {};
    var roots = (reply['roots'] as List?)?.cast<Map<String, Object?>>() ?? [];
    var root = NativeNode(
      role: 'application',
      children: [for (var tree in roots) _node(tree)],
    );
    _windows = windowSpanOf(root.children);
    var picture = screenshot ? await _screenshot() : null;
    return NativeObservation(
      platform: platform,
      coordinateSpace: coordinateSpace,
      root: root,
      screenshot: picture,
      screenshotScale: _scale,
      // Only where the picture is a crop. The simulator photographs the whole
      // simulated display, which starts where the tree's coordinates do.
      screenshotOrigin: simulatorUdid == null && picture != null
          ? _windows
          : null,
      note: platform == 'macos'
          ? 'On macOS this layer is for native chrome — menus, dialogs, save '
                "panels, other applications. A Flutter app's own widgets "
                'usually do not appear: the framework builds a semantics tree '
                'only when the *platform* asks, and nothing flutterware does '
                'asks it. A tree that is just a window title is expected here '
                '— address the app by dropping `layer`. '
                'Some apps do publish (an assistive client or VoiceOver '
                'turned it on for that process); if you see Flutter content '
                'below, it is real and you can use it. '
                '${_pictureSentence(wanted: screenshot, got: picture != null)}'
          : null,
    );
  }

  /// What the reply says about the picture's scope, which on macOS is the
  /// app's own windows rather than the screen they sit on.
  static String _pictureSentence({required bool wanted, required bool got}) {
    if (!wanted) return "The picture is this app's own windows.";
    return got
        ? "The picture is this app's own windows, not the desktop around them."
        : 'There is no picture: this app has no window on screen to '
              'photograph, and the desktop behind it is not this layer to '
              'show.';
  }

  /// `screencapture -R`'s rectangle: `x,y,w,h` in the same top-left-origin
  /// points the accessibility API reports, so nothing needs translating.
  static String _rectArgument(NativeBounds box) =>
      '${box.left.round()},${box.top.round()},'
      '${box.width.round()},${box.height.round()}';

  /// The rectangle this app's windows occupy, as of the last walk — what the
  /// picture is cropped to, and what a point is checked against.
  ///
  /// Null when the walk found no window with a frame, which is the one case
  /// where there is nothing of this app to photograph.
  NativeBounds? _windows;

  /// The smallest rectangle covering every one of [nodes] that has a frame.
  ///
  /// Null when none of them has one — the case the picture refuses on, rather
  /// than widening to the desktop.
  @visibleForTesting
  static NativeBounds? windowSpanOf(List<NativeNode> nodes) {
    NativeBounds? span;
    for (var node in nodes) {
      var box = node.bounds;
      if (box == null) continue;
      span = span == null
          ? box
          : NativeBounds(
              math.min(span.left, box.left),
              math.min(span.top, box.top),
              math.max(span.right, box.right),
              math.max(span.bottom, box.bottom),
            );
    }
    return span;
  }

  NativeNode _node(Map<String, Object?> json) {
    var bounds = (json['bounds'] as Map?)?.cast<String, Object?>();
    var node = NativeNode(
      role: json['role'] as String? ?? 'AXUnknown',
      label: json['label'] as String?,
      bounds: _bounds(bounds),
      clickable: json['clickable'] == true,
      enabled: json['enabled'] != false,
      focused: json['focused'] == true,
      checked: json['checked'] as bool?,
      children: [
        for (var child in (json['children'] as List?) ?? const [])
          _node((child as Map).cast<String, Object?>()),
      ],
    );
    if (json['path'] case String path) _paths[node] = path;
    return node;
  }

  static NativeBounds? _bounds(Map<String, Object?>? json) {
    if (json == null) return null;
    if (json case {
      'x': num x,
      'y': num y,
      'width': num width,
      'height': num height,
    }) {
      return NativeBounds(
        x.toDouble(),
        y.toDouble(),
        x.toDouble() + width.toDouble(),
        y.toDouble() + height.toDouble(),
      );
    }
    return null;
  }

  /// The device screen, or the app's window.
  ///
  /// `simctl io screenshot` rather than a window capture on the simulator: it
  /// photographs the simulated display itself, so there is no bezel, no
  /// scaling and nothing of the host in the picture.
  Future<List<int>?> _screenshot() async {
    try {
      if (simulatorUdid case var udid?) {
        var file = File(
          p.join(
            Directory.systemTemp.path,
            'flutterware-native-${DateTime.now().microsecondsSinceEpoch}.png',
          ),
        );
        var result = await Process.run('xcrun', [
          'simctl',
          'io',
          udid,
          'screenshot',
          file.path,
        ]);
        if (result.exitCode != 0 || !file.existsSync()) return null;
        var bytes = file.readAsBytesSync();
        file.deleteSync();
        return bytes;
      }
      // On macOS, this app's own windows and nothing else.
      //
      // The walk has been scoped that way from the start — "the tree includes
      // the host's own menu bar, the user's recent documents among it, which
      // is both noise in every reply and other people's business in an
      // agent's context" — and the picture simply never was. It photographed
      // the whole desktop, which on a real machine is other applications'
      // windows, and it went straight into an agent transcript: reported by a
      // consumer whose transcript ended up holding unrelated chat content and
      // a video player.
      //
      // The span of the windows rather than one of them, so a save panel or a
      // permission alert — the reason anyone comes to this layer — is in the
      // frame beside the window it belongs to. No window with a frame means
      // there is nothing of this app to photograph, and *that* is the case
      // the old code answered with the desktop.
      var within = _windows;
      if (within == null || within.isEmpty) return null;
      var file = File(
        p.join(
          Directory.systemTemp.path,
          'flutterware-native-${DateTime.now().microsecondsSinceEpoch}.png',
        ),
      );
      // `-R` takes the same top-left-origin points the accessibility API
      // reports, so the rect needs no translation. `-x` silences the shutter.
      var result = await Process.run('screencapture', [
        '-x',
        '-R',
        _rectArgument(within),
        file.path,
      ]);
      if (result.exitCode != 0 || !file.existsSync()) return null;
      var bytes = file.readAsBytesSync();
      file.deleteSync();
      return bytes;
    } on ProcessException {
      return null;
    }
  }

  /// The simulator device this driver drives, when it drives one.
  String? simulatorUdid;

  @override
  Future<void> tapNode(NativeNode node) async {
    var path = _paths[node];
    if (path == null) {
      // No path means the node did not come from this driver's last walk.
      // Falling back to its centre would be the wrong instinct: a coordinate
      // click needs the window frontmost and can land anywhere, while the
      // press it is standing in for cannot.
      var bounds = node.bounds;
      if (bounds == null) {
        throw NativeRefusal(
          '${node.describe()} cannot be pressed: it came from an older '
          'observation. Observe again and retry.',
          failure: 'notFound',
        );
      }
      await tapAt(bounds.centerX, bounds.centerY);
      return;
    }
    await _run({'cmd': 'press', 'path': path, 'expect': ?node.label});
  }

  @override
  Future<void> tapAt(double x, double y) async {
    await _run({'cmd': 'click', 'x': x, 'y': y});
  }

  @override
  Future<void> enterText(String text) async {
    // Measured, and the reason this is a refusal rather than a TODO:
    // `AXSetValue` on a focused field returns success and writes nothing
    // (S-N2). A verb that reports a lie is worse than one that admits it
    // cannot.
    throw NativeUnsupported(
      'The native layer cannot type on $platform: the accessibility API '
      'accepts the text and silently discards it, which is worse than '
      'refusing. Use the drive layer — drop `layer` and use enterText — which '
      'types through the app itself and keeps the platform keyboard in step.',
    );
  }

  /// Brings the app back, and on the simulator that means what a person would
  /// do rather than what the tooling offers.
  ///
  /// `xcrun simctl launch` on a running app **restarts** it — measured: fresh
  /// pid, state gone — which makes it useless for the case this verb exists
  /// for. Pressing Home and then the app's icon resumes it instead, with the
  /// screen it was on intact (measured: the next observe answered in 18ms with
  /// the counter where the agent left it).
  ///
  /// A device with no window gets one first — see [raiseDeviceWindow].
  @override
  Future<void> foreground() async {
    if (simulatorUdid case var udid?) {
      await raiseDeviceWindow(udid);
    } else {
      await _run({'cmd': 'foreground'});
    }
    if (simulatorUdid case var udid?) {
      var installed = await _installedApps(udid);
      await _run({
        'cmd': 'press',
        'scope': 'window',
        'label': 'Home',
        'in': 'AXToolbar',
      });
      await Future<void>.delayed(const Duration(milliseconds: 800));
      var icons = (await observe(screenshot: false)).speaking
          .where((node) => installed.contains(node.label))
          .toList();
      if (icons.isEmpty) {
        throw NativeRefusal(
          'Pressed Home, but no icon on this screen belongs to an app '
          'installed here (${installed.join(', ')}). The app may be on '
          'another home page — tap its icon by name once it is visible.',
          failure: 'notFound',
        );
      }
      if (icons.length > 1) {
        throw NativeRefusal(
          'Several apps installed here are on this screen: '
          '${icons.map((node) => '"${node.label}"').join(', ')}. Say which '
          'with a tap on the one you mean.',
          failure: 'multiple',
        );
      }
      await tapNode(icons.single);
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  /// Raises the simulator's window for [udid], opening one when it has none.
  ///
  /// A consumer's simulator had been booted with the Simulator app closed. The
  /// app on it sat `inactive` and drew nothing, and this verb — the way out of
  /// a stuck simulator app — answered "No running application matches
  /// com.apple.iphonesimulator"; with Simulator opened by hand, "No window
  /// of com.apple.iphonesimulator starts with iPhone 16". Both true, and both
  /// dead ends in exactly the state the verb is for.
  ///
  /// So a missing Simulator is launched, and a missing window is asked for the
  /// way a person asks for one: File › Open Simulator › runtime › device. The
  /// menu, because relaunching is no answer — a running Simulator ignores the
  /// arguments `open` passes it (measured), and quitting it would take every
  /// other device's window with it. Measured on a device detached from its
  /// window with Simulator running: the menu press brings the window back.
  @visibleForTesting
  Future<void> raiseDeviceWindow(String udid) async {
    String? missing;
    try {
      await _run({'cmd': 'foreground'});
      return;
    } on _HelperRefusal catch (e) {
      if (e.code != 'noApp' && e.code != 'noWindow') rethrow;
      missing = e.code;
    }
    if (missing == 'noApp') await launchSimulator(udid);
    var deadline = DateTime.now().add(windowDeadline);
    var path = [
      'File',
      'Open Simulator',
      await simulatorRuntime(udid),
      window!,
    ];
    try {
      // A Simulator that is still starting has no menu bar, or has one whose
      // device submenus are not filled in yet.
      await _untilAnswered(
        deadline,
        {'cmd': 'menu', 'path': path},
        transient: {'noApp', 'noMenu'},
      );
      await _untilAnswered(
        deadline,
        {'cmd': 'foreground'},
        transient: {'noApp', 'noWindow'},
      );
    } on _HelperRefusal catch (e) {
      throw NativeRefusal(
        '${missing == 'noApp' ? 'Launched Simulator and asked it' : 'Asked Simulator'} '
        'for this device (${path.join(' › ')}), and after '
        '${windowDeadline.inSeconds}s there is still no window to bring '
        'forward. ${e.said}',
        failure: e.failure,
      );
    }
  }

  /// How long [raiseDeviceWindow] waits for Simulator to start and show the
  /// window.
  @visibleForTesting
  var windowDeadline = const Duration(seconds: 20);

  /// Starts Simulator on [udid] — the selected Xcode's copy, the same Xcode
  /// `xcrun simctl` answers for, rather than whichever Launch Services
  /// prefers when two are installed.
  @visibleForTesting
  Future<void> Function(String udid) launchSimulator = _launchSimulator;

  /// The runtime [udid] runs, as Simulator's menu names it — `iOS 18.1`.
  @visibleForTesting
  Future<String> Function(String udid) simulatorRuntime = _simulatorRuntime;

  Future<void> _untilAnswered(
    DateTime deadline,
    Map<String, Object?> command, {
    required Set<String> transient,
  }) async {
    while (true) {
      try {
        await _run(command);
        return;
      } on _HelperRefusal catch (e) {
        if (!transient.contains(e.code) || DateTime.now().isAfter(deadline)) {
          rethrow;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  static Future<void> _launchSimulator(String udid) async {
    var developer = await Process.run('xcode-select', ['-p']);
    var bundle = p.join(
      '${developer.stdout}'.trim(),
      'Applications',
      'Simulator.app',
    );
    var result = await Process.run('open', [
      if (developer.exitCode == 0 && Directory(bundle).existsSync()) ...[
        '-a',
        bundle,
      ] else ...[
        '-b',
        'com.apple.iphonesimulator',
      ],
      // Read only by a Simulator that is starting: it opens this device's
      // window first rather than whichever it showed last.
      '--args',
      '-CurrentDeviceUDID',
      udid,
    ]);
    if (result.exitCode != 0) {
      throw NativeRefusal(
        'Could not start Simulator: ${'${result.stderr}'.trim()}',
        failure: 'unavailable',
      );
    }
  }

  static Future<String> _simulatorRuntime(String udid) async {
    var result = await Process.run('xcrun', ['simctl', 'list', '-j']);
    var name = result.exitCode == 0
        ? runtimeNameOf(udid, '${result.stdout}')
        : null;
    if (name == null) {
      throw NativeRefusal(
        '`xcrun simctl list` does not say which runtime $udid runs, so there '
        "is no way to find it in Simulator's menu. Open it there by hand.",
        failure: 'unavailable',
      );
    }
    return name;
  }

  /// The name of the runtime [udid] belongs to in `simctl list -j`'s
  /// [json] — the name Simulator's menu uses, which the device map's keys
  /// (`com.apple.CoreSimulator.SimRuntime.iOS-18-1`) are not.
  @visibleForTesting
  static String? runtimeNameOf(String udid, String json) {
    if (jsonDecode(json) case {
      'devices': Map devices,
      'runtimes': List runtimes,
    }) {
      for (var MapEntry(key: identifier, value: list) in devices.entries) {
        if (list is! List) continue;
        if (!list.any((device) => device is Map && device['udid'] == udid)) {
          continue;
        }
        for (var runtime in runtimes) {
          if (runtime case {'identifier': String id, 'name': String name}
              when id == identifier) {
            return name;
          }
        }
      }
    }
    return null;
  }

  /// The user-installed apps on a simulator, by display name.
  ///
  /// The names on the home screen are display names, so that is what this
  /// asks for; Apple's own apps are excluded by their bundle prefix, which is
  /// what keeps "press the app's icon" from meaning "press Safari".
  Future<Set<String>> _installedApps(String udid) async {
    var result = await Process.run('xcrun', ['simctl', 'listapps', udid]);
    if (result.exitCode != 0) return {};
    // The output is an old-style property list, and pulling two fields out of
    // it with a regexp beats taking a plist parser as a dependency for one
    // command that only ever runs while somebody waits for a suspended app.
    var text = '${result.stdout}';
    var names = <String>{};
    var pattern = RegExp(
      r'CFBundleDisplayName\s*=\s*"?([^";]+)"?;|CFBundleIdentifier\s*=\s*"?([^";]+)"?;',
    );
    String? pendingName;
    for (var match in pattern.allMatches(text)) {
      if (match.group(1) case var name?) pendingName = name.trim();
      if (match.group(2) case var id?) {
        if (pendingName != null && !id.trim().startsWith('com.apple.')) {
          names.add(pendingName);
        }
        pendingName = null;
      }
    }
    return names;
  }

  /// Compiles the helper, or returns the cached binary.
  ///
  /// Keyed by a hash of the source, so an edit to the Swift lands on the next
  /// call and a machine that already compiled it pays nothing. Cached beside
  /// the other run-time state rather than in the checkout: a hosted install's
  /// package directory is not reliably writable.
  static Future<String?> ensureHelper({String? sourceOverride}) async {
    if (!Platform.isMacOS) return null;
    var source = sourceOverride ?? await _helperSource();
    if (source == null) return null;
    var digest = sha1.convert(utf8.encode(source)).toString().substring(0, 12);
    var binary = File(p.join(flutterwareDir(), 'native', 'ax_helper-$digest'));
    if (binary.existsSync()) return binary.path;

    var scratch = Directory(p.join(binary.parent.path, 'build-$digest'))
      ..createSync(recursive: true);
    try {
      var swift = File(p.join(scratch.path, 'ax_helper.swift'))
        ..writeAsStringSync(source);
      var result = await Process.run('xcrun', [
        'swiftc',
        '-O',
        swift.path,
        '-o',
        binary.path,
      ]);
      if (result.exitCode != 0 || !binary.existsSync()) {
        throw NativeRefusal(
          'Could not build the accessibility helper: '
          '${'${result.stderr}'.trim()}',
          failure: 'unavailable',
        );
      }
      return binary.path;
    } on ProcessException catch (e) {
      throw NativeRefusal(
        'Could not build the accessibility helper — this needs the Xcode '
        'command line tools ($e).',
        failure: 'unavailable',
      );
    } finally {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }

  /// The helper's source, which ships beside this file.
  ///
  /// Found two ways because the two ways cover different lives of this code.
  /// `Isolate.resolvePackageUri` is exact, and it is what runs under the MCP
  /// server and the tests, which execute from source. It also **throws in an
  /// AOT binary** — which is what `fw` is — so the compiled CLI falls back to
  /// the app directory the launcher already tells it about. Found by the
  /// build, rather than by a comment claiming one of them always works.
  static Future<String?> _helperSource() async {
    const relative = 'lib/src/run/native/ax_helper.swift';
    try {
      var uri = await Isolate.resolvePackageUri(
        Uri.parse('package:flutterware_app/src/run/native/ax_helper.swift'),
      );
      if (uri != null) {
        var file = File.fromUri(uri);
        if (file.existsSync()) return file.readAsStringSync();
      }
    } on UnsupportedError {
      // AOT. The environment knows where the app package is.
    }
    for (var key in const [appToolPathKey, appPathEnvironmentKey]) {
      var root = Platform.environment[key];
      if (root == null || root.isEmpty) continue;
      var file = File(p.join(root, relative));
      if (file.existsSync()) return file.readAsStringSync();
    }
    return null;
  }

  /// Whether this machine will let the helper see anything, asked of the
  /// helper itself — the only way to know, since the permission database is
  /// readable only with full disk access.
  static Future<bool> isTrusted(String helper) async {
    try {
      var result = await Process.run(helper, [
        jsonEncode({'cmd': 'trusted'}),
      ]);
      var reply = jsonDecode(
        '${result.stdout}'.trim().split('\n').last,
      ) as Map<String, Object?>;
      return reply['trusted'] == true;
    } on Object {
      return false;
    }
  }
}

/// A refusal from the helper, with the code it gave — which [AxNativeDriver]
/// reads to tell a device with no window from a real failure.
class _HelperRefusal extends NativeRefusal {
  _HelperRefusal(
    super.message, {
    required this.code,
    required this.said,
    super.failure,
  });

  final String? code;

  /// The helper's own words, before this driver added the way out — for the
  /// refusal that comes from having already tried it.
  final String said;
}
