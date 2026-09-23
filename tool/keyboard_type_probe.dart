// Measures the software keyboard **per input type**, in logical pixels, on
// this device in portrait. The sibling of `keyboard_probe.dart`, which cycles
// orientations instead; the traps in its header apply here unchanged, and the
// first one bites hardest: disconnect the simulator's hardware keyboard or
// every reading is a confident zero.
//
// The question it answers is not "how tall is each type" but **how many
// classes there are** — a number pad and a phone pad may well be the same
// height, and email, URL and name are usually the same QWERTY with a different
// bottom row. Classes are what a table would have to carry.
//
//   flutter create kbtypes && cp keyboard_type_probe.dart kbtypes/lib/main.dart
//   cd kbtypes && flutter build ios --simulator --debug
//   xcrun simctl install <udid> build/ios/iphonesimulator/Runner.app
//   xcrun simctl launch  <udid> com.example.kbtypes
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// Every type a Flutter field can ask for, in the order a reader wants them:
/// the QWERTY family first, then the ones that might be a keypad.
final _types = <String, TextInputType>{
  'text': TextInputType.text,
  'multiline': TextInputType.multiline,
  'emailAddress': TextInputType.emailAddress,
  'url': TextInputType.url,
  'name': TextInputType.name,
  'streetAddress': TextInputType.streetAddress,
  'webSearch': TextInputType.webSearch,
  'visiblePassword': TextInputType.visiblePassword,
  'datetime': TextInputType.datetime,
  'phone': TextInputType.phone,
  'number': TextInputType.number,
  'number.decimal': TextInputType.numberWithOptions(decimal: true),
  'number.signed': TextInputType.numberWithOptions(signed: true),
  'number.signed.decimal': TextInputType.numberWithOptions(
    signed: true,
    decimal: true,
  ),
  // The control: a field that wants no system keyboard at all. Anything but
  // zero here means the platform disagrees with what Flutter documents, and
  // everything downstream of that assumption would be wrong.
  'none': TextInputType.none,
};

void main() => runApp(const TypeProbe());

class TypeProbe extends StatelessWidget {
  const TypeProbe({super.key});

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
  var _type = TextInputType.text;
  var _generation = 0;
  var _report = 'measuring…';

  @override
  void initState() {
    super.initState();
    unawaited(_measure());
  }

  Future<void> _measure() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    var lines = <String>[];
    for (var entry in _types.entries) {
      lines.add(await _once(entry.key, entry.value));
      if (mounted) setState(() => _report = lines.join('\n'));
    }
    await File('${Directory.systemTemp.path}/kbtypes.txt')
        .writeAsString('${lines.join('\n')}\n');
  }

  /// Takes the keyboard fully down, swaps the field for one asking [type], and
  /// waits for the insets to stop moving.
  ///
  /// **Down first, every time.** Switching type while the keyboard is up makes
  /// the platform *morph* it, and a reading taken during that morph is a frame
  /// of the animation rather than a height. Going through zero costs a second
  /// and removes the question.
  Future<String> _once(String name, TextInputType type) async {
    _focus.unfocus();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted) return 'KBTYPE $name abandoned';
      if (View.of(context).viewInsets.bottom == 0) break;
    }
    // A fresh key with the new type, so the framework attaches a new client
    // rather than updating the old one's configuration in place.
    setState(() {
      _type = type;
      _generation++;
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _focus.requestFocus();

    var settled = 0.0;
    var stable = 0;
    var raisedAt = -1;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // Ask again while nothing has come up — Android's first request after a
      // cold start lands before the window has focus and raises nothing, which
      // reads exactly like a device with no keyboard.
      if (settled == 0 && i % 8 == 7) {
        _focus.unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        _focus.requestFocus();
      }
      if (!mounted) return 'KBTYPE $name abandoned';
      var view = View.of(context);
      var bottom = view.viewInsets.bottom / view.devicePixelRatio;
      if (bottom > 0 && raisedAt < 0) raisedAt = i;
      if (bottom > 0 && (bottom - settled).abs() < 0.01) {
        stable++;
        // **Two stable samples are not enough, and this is why the letters
        // column exists as a control.** Raised from nothing, an iOS keyboard
        // arrives and *then* grows its predictive bar a beat later — so a rule
        // that stopped at the first plateau read 209 where the orientation
        // probe, which morphs an already-open keyboard, read 248 on the same
        // simulator. Thirty-nine points, silently, on every notched phone
        // before the 16.
        //
        // So: hold for two full seconds past the first non-zero reading and
        // take what it settles on. The cost is eight samples per measurement
        // and the run is still under a minute.
        if (stable >= 2 && i >= raisedAt + 8) break;
      } else {
        stable = 0;
      }
      settled = bottom;
    }
    if (!mounted) return 'KBTYPE $name abandoned';
    var view = View.of(context);
    var size = view.physicalSize / view.devicePixelRatio;
    var line =
        'KBTYPE $name keyboard=${settled.toStringAsFixed(1)} '
        'size=${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';
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
              key: ValueKey(_generation),
              focusNode: _focus,
              keyboardType: _type,
              decoration: const InputDecoration(labelText: 'Measure me'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Text(_report, style: const TextStyle(fontSize: 10)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
