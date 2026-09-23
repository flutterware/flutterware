import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutterware/plugins.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../constants.dart';
import '../shell/shell_controller.dart';
import 'settle.dart';
import 'settle_wait.dart';
import 'window_capture.dart';

/// The size, density and theme a capture is taken at, independent of the
/// machine taking it.
///
/// Layout, not the window. Resizing the real window would need a platform
/// dependency and would still be bounded by the display — a 1600×1200 shot is
/// impossible on a 13" laptop, and every screenshot would carry that laptop's
/// scale factor. Forcing the *layout* size inside the capture boundary needs
/// nothing: `toImage` rasterizes the boundary at whatever size it was laid out
/// at, whether or not that fits on screen. The window still opens at whatever
/// size the OS gives it and shows the content clipped; nobody is looking.
///
/// [pixelRatio] is overridden on the `MediaQuery` as well as handed to
/// `toImage`, so a guest — which sizes itself from what the panel reads — is
/// rendered at the density the picture is taken at rather than the display's.
class CaptureFraming {
  const CaptureFraming({this.size, this.pixelRatio, this.themeMode});

  final Size? size;
  final double? pixelRatio;

  /// Null follows the OS, which is the default and is wrong for anything
  /// committed: the same command on a laptop set to dark produces a different
  /// picture.
  final ThemeMode? themeMode;

  bool get isDefault => size == null && pixelRatio == null && themeMode == null;

  static CaptureFraming fromJson(Map<String, Object?> json) => CaptureFraming(
    size: switch ((json['width'], json['height'])) {
      (num width, num height) => Size(width.toDouble(), height.toDouble()),
      _ => null,
    },
    pixelRatio: (json['pixelRatio'] as num?)?.toDouble(),
    themeMode: switch (json['theme']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => null,
    },
  );

  /// Wraps [child] so it lays out at [size] regardless of the window.
  ///
  /// `OverflowBox` rather than `SizedBox`: the incoming constraints are the
  /// window's, and a `SizedBox` would be clamped by them — which is the whole
  /// difficulty, since the requested size is usually larger than whatever the
  /// OS opened.
  Widget frame(BuildContext context, Widget child) {
    if (size == null && pixelRatio == null) return child;
    var media = MediaQuery.of(context);
    var framed = MediaQuery(
      data: media.copyWith(
        size: size ?? media.size,
        devicePixelRatio: pixelRatio ?? media.devicePixelRatio,
      ),
      child: child,
    );
    if (size case var box?) {
      return OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: box.width,
        maxWidth: box.width,
        minHeight: box.height,
        maxHeight: box.height,
        child: framed,
      );
    }
    return framed;
  }
}

/// What `fw capture` asked the GUI for. See [captureRequestKey] for the wire
/// format and why the name of it lives somewhere else.
class CaptureRequest {
  CaptureRequest({
    required this.address,
    required this.output,
    this.framing = const CaptureFraming(),
    this.settleTimeout = const Duration(minutes: 3),
  });

  final CaptureFraming framing;

  /// Where to go first. Null captures wherever the shell lands on its own,
  /// which is the launch worktree's home screen.
  final Address? address;

  final File output;

  /// How long the window may keep working before it is photographed anyway.
  ///
  /// Generous, because the thing it is usually waiting for is a cold compile
  /// of a catalog entry. Reaching it is reported rather than fatal: a picture
  /// of a spinner plus a line saying what was still running beats no picture
  /// and no explanation.
  final Duration settleTimeout;

  static CaptureRequest? fromEnvironment([Map<String, String>? environment]) {
    var raw = (environment ?? Platform.environment)[captureRequestKey];
    if (raw == null || raw.isEmpty) return null;
    var json = jsonDecode(raw) as Map<String, Object?>;
    var address = json['address'] as String?;
    return CaptureRequest(
      address: address == null ? null : Address.parse(address),
      output: File(json['output']! as String),
      framing: CaptureFraming.fromJson(json),
      settleTimeout: switch (json['settleTimeout']) {
        num seconds => Duration(milliseconds: (seconds * 1000).round()),
        _ => const Duration(minutes: 3),
      },
    );
  }

  /// Everything after `runApp`: navigate, settle, photograph, write.
  ///
  /// Returns the process exit code. Never throws — a capture that failed has
  /// to say so on stdout in the same shape a capture that worked does, because
  /// the caller is a script reading JSON, not a person reading a stack trace.
  Future<int> run(
    ShellController shell,
    GlobalKey boundaryKey,
    SettleRegistry settleRegistry,
  ) async {
    try {
      if (address case var destination?) {
        var result = shell.go(_resolve(destination, shell));
        if (result == GoResult.worktreeUnknown) {
          return _fail('no worktree matches "${destination.worktree}"');
        }
      }

      var waitedOn = <String>{};
      var outcome = await waitForSettle(
        settleRegistry,
        timeout: settleTimeout,
        onWaiting: waitedOn.addAll,
      );

      if (_landingError(shell) case var complaint?) return _fail(complaint);

      var boundary =
          boundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return _fail('the window has not rendered');

      var image = await WindowCapture.capture(
        boundary,
        pixelRatio: _pixelRatioOf(boundaryKey),
      );
      output.parent.createSync(recursive: true);
      await output.writeAsBytes(img.encodePng(image));
      _report({
        'ok': true,
        'output': p.absolute(output.path),
        'address': shell.address.toString(),
        'width': image.width,
        'height': image.height,
        'settled': outcome.settled,
        // Reported on a *settled* capture too, not only a timed-out one: a
        // picture that came back half-drawn is answered by knowing what the
        // window was — or was not — waiting on, and by then the run is over.
        'waitedOn': waitedOn.toList()..sort(),
        if (!outcome.settled) 'waitingOn': outcome.waitingOn,
      });
      return 0;
    } on Object catch (e, stack) {
      return _fail('$e', stack);
    }
  }

  /// Why the window is not showing what was asked for, or null when it is.
  ///
  /// The failure this exists for is silent. [ShellController.go] accepts an
  /// address whose plugin no worktree declares, writes it to the bar, and
  /// renders the home screen — deliberately, because a reloaded config may drop
  /// a plugin and a panel that cannot be built is worse than a fallback. For a
  /// human that is right. For a script it is the worst possible outcome: a
  /// screenshot of the overview page, reported as a success, filed under the
  /// name of the panel it was supposed to show.
  ///
  /// The list of ids is in the message because the cause is almost always a
  /// short name where a full one belongs — `ui_catalog` for
  /// `flutterware.previews`, which is exactly the mistake that produced this
  /// check.
  ///
  /// The segments are checked too, and skipping them let the worst version of
  /// this through. The plugin test only ever asked "is this the right panel",
  /// and a catalog panel that could not reach the entry it was asked for does
  /// not fail — it opens on another one and writes that back to the address.
  /// Measured: a capture of `demo/buttons.dart#buttons` came back reporting
  /// `ok: true` with a picture of `demo/asset_smoke.dart#assetSmoke`, filed
  /// under the name of the demo it was supposed to show. Right panel, wrong
  /// subject, and nothing anywhere said so.
  ///
  /// Axes are deliberately not compared. A panel resolves them — `?device=` is
  /// answered, a knob picks up its default — so the address that comes back
  /// carries more than the one that went in, legitimately. What must match is
  /// *what is being shown*, which is the plugin and the segments.
  String? _landingError(ShellController shell) => landingError(
    wanted: address,
    landedPlugin: shell.shownScreenId,
    landedSegments: shell.address.segments,
    declared: shell.selectedSession?.plugins.map((p) => p.id).toList(),
  );

  /// Fills in the worktree the shell already opened, when the address named a
  /// plugin without one.
  ///
  /// The plugin test is what makes this safe, and it was added because the
  /// explorer broke it. This used to fill in a worktree whenever the address
  /// lacked one, on the reasoning that no parseable address could — the worktree
  /// slot being positional ahead of the plugin. `fw:///worktrees` is exactly
  /// that address: a complete, deliberately worktree-less place, and rewriting
  /// it sent `fw capture fw:///worktrees` to a worktree's panel instead, which
  /// reported success and produced a picture of the wrong screen.
  ///
  /// An address naming a plugin but no worktree is still unreachable through the
  /// parser, so this remains a shape the CLI cannot yet produce. The gap it was
  /// written for is real — a documentation script should not have to write this
  /// machine's branch name — and closing it is a relative form on the CLI or a
  /// correction to the spec, which is a decision rather than a cleanup.
  static Address _resolve(Address destination, ShellController shell) =>
      destination.worktree != null || destination.plugin == null
      ? destination
      : destination.copyWith(worktree: shell.address.worktree);

  /// The density the picture is taken at — the requested one, or the display's
  /// when nothing was asked for.
  double _pixelRatioOf(GlobalKey key) =>
      framing.pixelRatio ?? View.of(key.currentContext!).devicePixelRatio;

  int _fail(String message, [StackTrace? stack]) {
    _report({
      'ok': false,
      'error': message,
      if (stack != null) 'stack': '$stack',
    });
    return 1;
  }

  /// On stdout, as JSON, because the reader is `fw capture`.
  static void _report(Map<String, Object?> body) =>
      stdout.writeln(jsonEncode(body));
}

/// The landing check itself, off the controller so it can be tested.
///
/// See [CaptureRequest._landingError] for what it is protecting against;
/// everything it needs is four plain values, and a `ShellController` is not one
/// of the things a test of "did we land where we were sent" should have to
/// build.
String? landingError({
  required Address? wanted,
  required String? landedPlugin,
  required List<String> landedSegments,
  required List<String>? declared,
}) {
  if (wanted?.plugin == null) return null;
  if (landedPlugin != wanted!.plugin) {
    return [
      'the window did not land on "${wanted.plugin}".',
      if (declared != null && declared.isNotEmpty)
        'This worktree declares: ${declared.join(', ')}.',
    ].join(' ');
  }
  if (wanted.segments.isEmpty ||
      const ListEquality<String>().equals(landedSegments, wanted.segments)) {
    return null;
  }
  return 'the window landed on "${landedSegments.join('/')}" rather than '
      '"${wanted.segments.join('/')}". The panel opened, but on something '
      'else — usually because what was asked for is not there.';
}
