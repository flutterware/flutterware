import 'package:flutterware_app/src/embedder/tester_host.dart';
import 'package:test/test.dart';

void main() {
  test('the rasterizer is named the way the arguments choose it', () {
    expect(
      rasterizerName(macOS: true, environment: const {}),
      'impeller-metal',
    );
    expect(
      rasterizerName(macOS: false, environment: const {}),
      'impeller-vulkan',
    );
    expect(
      rasterizerName(
        macOS: true,
        environment: const {'FW_SOFTWARE_RENDERING': '1'},
      ),
      'skia-software',
    );
  });

  group('rasterizerArguments', () {
    test('names Metal on macOS, because a build hook compiled for it', () {
      expect(rasterizerArguments(macOS: true, environment: const {}), [
        '--enable-impeller',
        '--impeller-backend=metal',
        '--enable-flutter-gpu',
      ]);
    });

    test(
      'names no backend elsewhere — the default is what the hook targeted',
      () {
        expect(rasterizerArguments(macOS: false, environment: const {}), [
          '--enable-impeller',
          '--enable-flutter-gpu',
        ]);
      },
    );

    test('Flutter GPU is never asked for without Impeller', () {
      for (var macOS in [true, false]) {
        var args = rasterizerArguments(macOS: macOS, environment: const {});
        expect(
          args.contains('--enable-flutter-gpu'),
          args.contains('--enable-impeller'),
          reason: 'the engine ANDs the two; one alone renders nothing',
        );
      }
    });

    test('the escape hatch puts the software rasterizer back', () {
      var args = rasterizerArguments(
        macOS: true,
        environment: const {'FW_SOFTWARE_RENDERING': '1'},
      );
      expect(args, [
        '--enable-software-rendering',
        '--skia-deterministic-rendering',
      ]);
      expect(args, isNot(contains('--enable-impeller')));
    });

    test('only an exact 1 opts out — an empty value is not a switch', () {
      for (var value in ['', '0', 'true', 'yes']) {
        expect(
          rasterizerArguments(
            macOS: true,
            environment: {'FW_SOFTWARE_RENDERING': value},
          ),
          contains('--enable-impeller'),
          reason: 'FW_SOFTWARE_RENDERING=$value',
        );
      }
    });
  });
}
