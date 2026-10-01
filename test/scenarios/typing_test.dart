import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutterware/flutter_test.dart';

/// `enterText(…, typing:)`: the value arrives a character at a time, with the
/// fake clock moving between keystrokes, instead of in one edit.
///
/// Reported by a consumer whose search field debounces its query: set in one
/// edit, the debounce saw a single change and the flow never exercised it.
void main() {
  group('without typing', () {
    scenario('the value arrives in one edit, as before', (s) async {
      var field = _Debounced();
      await s.pumpWidget(field.app());

      await s.enterText(TextField, 'coffee');
      await s.wait(_Debounced.delay);

      expect(field.changes, ['coffee']);
      expect(field.searches, ['coffee']);
    });
  });

  group('typing', () {
    scenario('delivers every character as its own edit', (s) async {
      var field = _Debounced();
      await s.pumpWidget(field.app());

      await s.enterText(
        TextField,
        'coffee',
        typing: const Duration(milliseconds: 100),
      );

      expect(field.changes, ['c', 'co', 'cof', 'coff', 'coffe', 'coffee']);
      expect(find.text('coffee'), findsOneWidget);
      await s.wait(_Debounced.delay);
    });

    // The case the option exists for: the debounce restarts on every
    // keystroke and fires once, on the whole query — not once per character,
    // and not never.
    scenario('fires a debounce once, after the typing stops', (s) async {
      var field = _Debounced();
      await s.pumpWidget(field.app());

      await s.enterText(
        TextField,
        'coffee',
        typing: const Duration(milliseconds: 100),
      );
      await s.wait(_Debounced.delay);

      expect(field.searches, ['coffee']);
    });

    // And the clock really moves between keystrokes: typed slower than the
    // debounce waits, it fires on every one of them.
    scenario('typed slower than the debounce, fires it every time', (s) async {
      var field = _Debounced();
      await s.pumpWidget(field.app());

      await s.enterText(
        TextField,
        'tea',
        typing: _Debounced.delay + const Duration(milliseconds: 50),
      );

      expect(field.searches, ['t', 'te', 'tea']);
    });

    // A keystroke is a grapheme: an accent written as a combining mark and an
    // emoji each arrive whole, never as half a surrogate pair.
    scenario('types what one key types', (s) async {
      var field = _Debounced();
      await s.pumpWidget(field.app());

      await s.enterText(
        TextField,
        'né☕',
        typing: const Duration(milliseconds: 50),
      );

      expect(field.changes, ['n', 'né', 'né☕']);
      await s.wait(_Debounced.delay);
    });
  });
}

/// A search field that waits [delay] after the last edit before it searches.
class _Debounced {
  static const delay = Duration(milliseconds: 300);

  final changes = <String>[];
  final searches = <String>[];
  Timer? _timer;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: TextField(
        onChanged: (value) {
          changes.add(value);
          _timer?.cancel();
          _timer = Timer(delay, () => searches.add(value));
        },
      ),
    ),
  );
}
