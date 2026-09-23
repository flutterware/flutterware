// Measures the software keyboard: how tall it is, in logical pixels, on this
// device, in each orientation. The numbers in `lib/src/devices.dart` come from
// running this, and re-running it is how they are checked against a new OS.
//
// Not a program this repo builds — a device probe has to be a real app on a
// real device, and this package is a library. Drop it in:
//
//   flutter create kbprobe && cp tool/keyboard_probe.dart kbprobe/lib/main.dart
//   cd kbprobe && flutter build ios --simulator --debug   # or: build apk --debug
//
// Then install it on each device and read the two KBRESULT lines it prints:
//
//   xcrun simctl install <udid> build/ios/iphonesimulator/Runner.app
//   xcrun simctl launch  <udid> com.example.kbprobe
//   xcrun simctl spawn   <udid> log show --last 2m \
//     --predicate 'eventMessage CONTAINS "KBRESULT"' --style compact
//
//   adb install -r -t build/app/outputs/flutter-apk/app-debug.apk
//   adb logcat -s flutter:V        # while it runs; the unfiltered buffer rolls
//
// Three traps, each of which produced a confident wrong number first:
//
//  - **Disconnect the simulator's hardware keyboard** — `defaults write
//    com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` — or no
//    software keyboard appears and every reading is zero.
//  - **An iPad ignores `setPreferredOrientations`.** Its landscape number needs
//    `UISupportedInterfaceOrientations~ipad` edited in the built bundle
//    *before* `simctl install`; iOS reads the plist at install time.
//  - **Android needs the display it will be measured at**, because the
//    keyboard's height moves with density as much as with size: `adb shell wm
//    size <w>x<h>` and `wm density <d>` for each entry in the table, at the
//    ratio that entry declares — then `wm size reset`, `wm density reset`.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

void main() => runApp(const KeyboardProbe());

class KeyboardProbe extends StatelessWidget {
  const KeyboardProbe({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(debugShowCheckedModeBanner: false, home: _Probe());
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  final _focus = FocusNode();
  var _report = 'measuring…';

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    var portrait = await _once('portrait');
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
    ]);
    // The rotation is an animation, and the keyboard resizes with it.
    await Future<void>.delayed(const Duration(seconds: 3));
    var landscape = await _once('landscape');
    if (mounted) setState(() => _report = '$portrait\n$landscape');
    // Also on disk, for a device whose console is hard to read.
    await File('${Directory.systemTemp.path}/kbresult.txt')
        .writeAsString('$portrait\n$landscape\n');
  }

  /// Raises the keyboard and waits for the insets to stop moving.
  Future<String> _once(String orientation) async {
    _focus.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _focus.requestFocus();
    var settled = 0.0;
    var stable = 0;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // Ask again while nothing has come up. On Android the first request
      // after a cold start lands before the window has focus and the IME never
      // appears — which reads exactly like a device that has no keyboard.
      if (settled == 0 && i % 8 == 7) {
        _focus.unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _focus.requestFocus();
      }
      if (!mounted) break;
      var view = View.of(context);
      var bottom = view.viewInsets.bottom / view.devicePixelRatio;
      // Two identical non-zero readings: the raise animates, and the first
      // frame after it starts is not the height it lands on.
      if (bottom > 0 && (bottom - settled).abs() < 0.01) {
        stable++;
        if (stable >= 2) break;
      } else {
        stable = 0;
      }
      settled = bottom;
    }
    if (!mounted) return 'KBRESULT $orientation abandoned';
    var view = View.of(context);
    var ratio = view.devicePixelRatio;
    var size = view.physicalSize / ratio;
    var padding = view.padding;
    var line =
        'KBRESULT $orientation keyboard=${settled.toStringAsFixed(1)} '
        'size=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)} '
        'ratio=$ratio '
        'padding=${(padding.top / ratio).toStringAsFixed(0)},'
        '${(padding.bottom / ratio).toStringAsFixed(0)},'
        '${(padding.left / ratio).toStringAsFixed(0)},'
        '${(padding.right / ratio).toStringAsFixed(0)}'
        '${settled == 0 ? ' NO-KEYBOARD (hardware keyboard connected?)' : ''}';
    debugPrint(line);
    return line;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              focusNode: _focus,
              decoration: const InputDecoration(labelText: 'Measure me'),
            ),
            const SizedBox(height: 16),
            Text(_report, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    ),
  );
}
