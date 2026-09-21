import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware/src/scenarios/scenario.dart';
import 'package:path/path.dart' as p;

/// What files a standalone capture under a screenshots destination: the file
/// the `scenario()` call was written in, read off the declaring stack because
/// a bare `flutter test` says it nowhere else.
void main() {
  test('answers the caller of scenario(), package-relative', () {
    var file = p.join(
      Directory.current.path,
      'test',
      'scenarios',
      'a_test.dart',
    );
    expect(
      scenarioDeclaringFile(
        StackTrace.fromString(
          '#0      scenario (package:flutterware/src/scenarios/scenario.dart:72:3)\n'
          '#1      main (${Uri.file(file)}:12:3)\n'
          '#2      _runTest (package:flutter_test/src/binding.dart:1:1)\n',
        ),
      ),
      'test/scenarios/a_test.dart',
    );
  });

  test('skips our frames however the runtime spelled them', () {
    var checkout = '/checkout/flutterware/lib/src/scenarios/scenario.dart';
    expect(
      scenarioDeclaringFile(
        StackTrace.fromString(
          '#0      scenario (file://$checkout:72:3)\n'
          '#1      main (file:///elsewhere/test/pay_test.dart:12:3)\n',
        ),
      ),
      // Outside the package, so absolute, and as the platform spells it.
      p.join(p.separator, 'elsewhere', 'test', 'pay_test.dart'),
    );
  });

  test('a real trace parses — the format this is read from', () {
    expect(
      scenarioDeclaringFile(StackTrace.current),
      'test/scenarios/declaring_file_test.dart',
    );
  });

  test('says nothing rather than guessing when no frame is a file', () {
    expect(
      scenarioDeclaringFile(
        StackTrace.fromString('#0      scenario (package:some/where.dart:1:1)'),
      ),
      isNull,
    );
  });
}
