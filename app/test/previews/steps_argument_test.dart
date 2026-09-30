import 'package:flutter_test/flutter_test.dart';
import 'package:flutterware_app/src/plugins/native/previews_core.dart';

/// How `--steps` gets from an agent or a command line to the harness: in
/// `act`'s wire spelling, every value a string, so the harness hands each one
/// to the same dispatch a live `act` goes through.
void main() {
  test('a list of act steps arrives as the wire spells them', () {
    expect(
      PreviewsCore.parseSteps([
        {'verb': 'tap', 'target': 'Coffee'},
        {
          'verb': 'hover',
          'target': {'tooltip': 'Add to cart'},
          'holdMs': 800,
        },
      ]),
      [
        {'verb': 'tap', 'target': 'Coffee'},
        // An object target becomes the JSON `act` would have been handed,
        // and a number the text a service extension carries.
        {
          'verb': 'hover',
          'target': '{"tooltip":"Add to cart"}',
          'holdMs': '800',
        },
      ],
    );
  });

  test('a shell sends the same list as text', () {
    expect(PreviewsCore.parseSteps('[{"verb": "key", "keys": "esc"}]'), [
      {'verb': 'key', 'keys': 'esc'},
    ]);
    expect(PreviewsCore.parseSteps(null), isEmpty);
  });

  test('a step without a verb is refused, saying which', () {
    expect(
      () => PreviewsCore.parseSteps([
        {'verb': 'tap', 'target': 'A'},
        {'target': 'B'},
      ]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('step 2'),
        ),
      ),
    );
  });

  test('an item is refused: there is no reply whose screen it numbers', () {
    expect(
      () => PreviewsCore.parseSteps([
        {'verb': 'tap', 'item': 3},
      ]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          contains('Name the target'),
        ),
      ),
    );
  });
}
