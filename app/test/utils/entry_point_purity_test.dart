import 'dart:io';

import 'package:flutterware_app/src/utils/import_walker.dart';
import 'package:package_config/package_config.dart';
import 'package:test/test.dart';

/// Entry points that must never reach Flutter.
///
/// Purity is a property of the entry point's import closure, not of the
/// package. `flutterware_app` is a Flutter package that also holds pure-Dart
/// entry points, and the only thing keeping them pure is that nobody adds the
/// wrong import.
///
/// The stated guardrail is that `dart compile exe` fails. That is true but
/// late: it fires at distribution time, only for the entry points that get
/// compiled, and the symptom of getting this wrong was a compiler fork bomb
/// that filled the machine in seconds. This runs the same check in
/// milliseconds, and prints the chain.
const _pureEntryPoints = [
  // `fw` — the CLI renderer. The one that matters most day to day: a plugin's
  // panel returns a `Widget`, so reaching one from here makes `fw` unlinkable.
  'bin/fw.dart',
  // The MCP server. Same contract, same reason.
  'bin/mcp.dart',
  // Writes docs/capabilities.md. Pure for the same reason `fw` is: it
  // resolves cores, and a core that reached a panel would drag in Flutter.
  'tool/generate_capabilities.dart',
  // The catalog compile daemon. `ResidentCompiler` spawns
  // `Platform.resolvedExecutable`; inside a Flutter binary that is the app,
  // which starts a session, which asks for a compiler. Each generation
  // doubles. This entry is the one that must never regress.
  'tool/catalog/compiler_daemon.dart',
  // Drives that daemon as a process. Listed because it is run by `dart test`
  // rather than `flutter test`, which is what lets it spawn one — an import
  // that reached Flutter would make it unloadable rather than merely slow.
  'integration_test/compiler_daemon_test.dart',
];

/// `dart:ui` is listed as well as `package:flutter` because it is the thing
/// that actually cannot load in a plain VM; `package:flutter` is merely the
/// usual way to reach it.
const _forbidden = ['package:flutter', 'dart:ui'];

void main() async {
  var packageConfig = (await findPackageConfig(Directory.current))!;

  group('pure entry points', () {
    for (var entryPoint in _pureEntryPoints) {
      test('$entryPoint reaches no Flutter', () {
        var file = File(entryPoint);
        expect(
          file.existsSync(),
          isTrue,
          reason:
              'Entry point $entryPoint does not exist. If it moved, update '
              'this list — do not delete the entry.',
        );

        var result = ImportWalker(packageConfig)
            .walk(Uri.base.resolve(entryPoint));

        for (var target in _forbidden) {
          var hits = result.findReachable(target).toList();
          if (hits.isEmpty) continue;
          var chain = result.chainTo(hits.first).join('\n  → ');
          fail(
            '$entryPoint reaches forbidden library `$target`.\n'
            'This entry point is compiled with `dart compile exe` or run on a '
            'plain Dart VM, where package:flutter cannot load.\n'
            'Import chain:\n  $chain',
          );
        }
      });
    }
  });

  group('the walker itself', () {
    test('finds a real Flutter dependency, so a pass means something', () {
      // A GUI entry point must fail the same check the pure ones pass —
      // otherwise a walker that silently resolved nothing would look green.
      var result = ImportWalker(packageConfig)
          .walk(Uri.base.resolve('lib/main.dart'));
      expect(result.findReachable('package:flutter'), isNotEmpty);
    });

    test('package:flutter does not match package:flutterware', () {
      var result = ImportWalker(packageConfig)
          .walk(Uri.base.resolve('tool/flutterware_purity_fixture.dart'));
      // The fixture imports package:flutterware and nothing else. If the
      // prefix rule were `startsWith('package:flutter')` this would match.
      expect(result.findReachable('package:flutterware'), isNotEmpty);
      expect(result.findReachable('package:flutter'), isEmpty);
    });
  });
}
