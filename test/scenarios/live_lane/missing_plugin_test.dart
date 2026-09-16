import 'package:flutter/services.dart';
import 'package:flutterware/flutter_test.dart';

void main() {
  scenario('a channel nobody answers is described with the two fixes', (
    s,
  ) async {
    const channel = MethodChannel('probe/nobody');
    Object? error;
    try {
      await channel.invokeMethod<void>('ping');
    } catch (e) {
      error = e;
    }
    expect(error, isA<MissingPluginException>());
    for (var form in [error!, error.toString()]) {
      var refusal = describePluginFailure(form);
      expect(refusal, contains('probe/nobody'));
      expect(refusal, contains('method ping'));
      expect(refusal, contains('has no host on flutter_tester'));
      expect(
        refusal,
        contains(
          "setMockMethodCallHandler(const MethodChannel('probe/nobody')",
        ),
      );
      expect(refusal, contains('inject the value'));
    }
    expect(describePluginFailure(StateError('other')), 'Bad state: other');
  });
}
