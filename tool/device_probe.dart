// What a device tells an app about its screen: its size, its ratio, its safe
// areas and its cutouts, and how tall the software keyboard comes up — in
// portrait and on both sides. The numbers in `lib/src/devices.dart` are this
// app's readings, and `tool/measure_devices.dart` is how they are taken: it
// drops this file into a fresh `flutter create` as its `lib/main.dart`, runs it
// on a throwaway simulator or emulator per table row, and compares.
//
// Not a program this repo builds — a device probe has to be a real app on a
// real device, and this package is a library. Widgets only, no Material, so it
// needs nothing but the SDK.
//
// It writes one JSON object to `${Directory.systemTemp.path}/device_probe.json`
// and prints it after `DEVICE_PROBE `:
//
//   {"portrait": {"size": [393, 852], "ratio": 3, "insets": [l, t, r, b],
//                 "cutouts": [[l, t, r, b]], "keyboard": 335, "keypad": 308,
//                 "control": 335}, ...}
//
// `keypad` is what a number field gets, and `control` is the letters keyboard
// raised again after it: a keypad reading only counts when the control agrees
// with the letters one taken before it.
//
// Four traps, each of which produced a confident wrong number first:
//
//  - **Disconnect the simulator's hardware keyboard** — `defaults write
//    com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` — or no
//    software keyboard appears and every keyboard reading is zero.
//  - **A fresh simulator introduces its keyboards** the first time one comes
//    up, in a card where the keys will be — with two input languages, a "type
//    in both" card 248 points tall in landscape. The probe raises one in each
//    orientation and throws the readings away before it measures anything.
//  - **The landscape keyboard settles a point late** on iOS 26: two equal
//    readings a quarter of a second apart give 208, and it lands on 209. A
//    reading counts once it has held still for a second and a half.
//  - **An iPad ignores `setPreferredOrientations`** unless the app declares
//    `UIRequiresFullScreen`, which is what the driver adds to the plist.
//
// Which keyboard each input type gets, rather than how tall the two families
// are, is `tool/keyboard_type_probe.dart`'s question.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const DeviceProbe());

class DeviceProbe extends StatefulWidget {
  const DeviceProbe({super.key});

  @override
  State<DeviceProbe> createState() => _DeviceProbeState();
}

class _DeviceProbeState extends State<DeviceProbe> {
  final _focus = FocusNode();
  final _text = TextEditingController();
  var _type = TextInputType.text;
  var _report = 'measuring…';

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    // Raised once each way up and thrown away: see the introduction card in
    // the header.
    for (var orientation in [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
    ]) {
      await SystemChrome.setPreferredOrientations([orientation]);
      await _turned(landscape: orientation != DeviceOrientation.portraitUp);
      await _keyboard(TextInputType.text);
    }

    var readings = <String, Object?>{};
    for (var (name, orientation) in [
      ('portrait', DeviceOrientation.portraitUp),
      ('landscapeLeft', DeviceOrientation.landscapeLeft),
      ('landscapeRight', DeviceOrientation.landscapeRight),
    ]) {
      await SystemChrome.setPreferredOrientations([orientation]);
      await _turned(landscape: name != 'portrait');
      readings[name] = {
        ..._screen(),
        'keyboard': await _keyboard(TextInputType.text),
        'keypad': await _keyboard(TextInputType.number),
        'control': await _keyboard(TextInputType.text),
      };
    }
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    var line = jsonEncode(readings);
    await File('${Directory.systemTemp.path}/device_probe.json')
        .writeAsString(line);
    debugPrint('DEVICE_PROBE $line');
    if (mounted) setState(() => _report = line);
  }

  ui.FlutterView get _view => View.of(context);

  /// Waits for the screen to be the right way up and to stop moving: a
  /// rotation animates, and the insets arrive a frame or two after the size.
  Future<void> _turned({required bool landscape}) async {
    String? last;
    var still = DateTime.now();
    var deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      var reading = jsonEncode(_screen());
      if (reading != last) {
        last = reading;
        still = DateTime.now();
      }
      var size = _view.physicalSize;
      if ((size.width > size.height) == landscape &&
          DateTime.now().difference(still) >
              const Duration(milliseconds: 1200)) {
        return;
      }
    }
  }

  Map<String, Object?> _screen() {
    var ratio = _view.devicePixelRatio;
    double logical(double physical) =>
        (physical / ratio * 100).roundToDouble() / 100;
    List<double> box(double l, double t, double r, double b) => [
      logical(l),
      logical(t),
      logical(r),
      logical(b),
    ];
    var padding = _view.viewPadding;
    return {
      'size': [
        logical(_view.physicalSize.width),
        logical(_view.physicalSize.height),
      ],
      'ratio': ratio,
      'insets': box(padding.left, padding.top, padding.right, padding.bottom),
      'cutouts': [
        for (var feature in _view.displayFeatures)
          if (feature.type == ui.DisplayFeatureType.cutout)
            box(
              feature.bounds.left,
              feature.bounds.top,
              feature.bounds.right,
              feature.bounds.bottom,
            ),
      ],
    };
  }

  /// Raises the keyboard a field of [type] asks for and waits for its height
  /// to stop moving, then lowers it again. Zero means none came up — on a
  /// simulator that is almost always the hardware keyboard still being
  /// connected.
  Future<double> _keyboard(TextInputType type) async {
    _focus.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return 0;
    // The type rides the connection the field opens on focus, so it is set
    // while the field is unfocused and the next focus asks for it.
    setState(() => _type = type);
    await WidgetsBinding.instance.endOfFrame;
    _focus.requestFocus();
    var settled = 0.0;
    var stable = 0;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted) return 0;
      // Ask again while nothing has come up. On Android the first request
      // after a cold start lands before the window has focus and the IME never
      // appears — which reads exactly like a device that has no keyboard.
      if (settled == 0 && i % 8 == 7) {
        _focus.unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _focus.requestFocus();
      }
      var height = _view.viewInsets.bottom / _view.devicePixelRatio;
      // Still for a second and a half: the raise animates, and on iOS 26 a
      // landscape keyboard moves its last point well after it looks done.
      if (height > 0 && (height - settled).abs() < 0.01) {
        if (++stable >= 6) break;
      } else {
        stable = 0;
      }
      settled = height;
    }
    _focus.unfocus();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return (settled * 10).roundToDouble() / 10;
  }

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: const Color(0xFFFFFFFF),
    builder: (context, _) => ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EditableText(
                controller: _text,
                focusNode: _focus,
                keyboardType: _type,
                style: const TextStyle(fontSize: 17, color: Color(0xFF000000)),
                cursorColor: const Color(0xFF000000),
                backgroundCursorColor: const Color(0xFF888888),
              ),
              const SizedBox(height: 16),
              Text(
                _report,
                style: const TextStyle(fontSize: 11, color: Color(0xFF000000)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
