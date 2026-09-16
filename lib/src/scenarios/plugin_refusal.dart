import 'package:flutter/services.dart' show MissingPluginException;

/// A `MissingPluginException` as a sentence a scenario author can act on.
///
/// The exception names the channel and the method; what it does not say is
/// that this is *expected* on `flutter_tester` — there is no plugin
/// registrant, so a plugin's platform half never runs — and that the fix is
/// one of two lines the fake-time lane already uses everywhere. Anything that
/// is not that exception, or a message that does not carry one, comes back
/// as it was.
String describePluginFailure(Object error) {
  var text = switch (error) {
    MissingPluginException(:var message) => message ?? '',
    String text => text,
    _ => error.toString(),
  };
  var match = _missing.firstMatch(text);
  if (match == null) return error.toString();
  var method = match.group(1);
  var channel = match.group(2);
  return 'Channel $channel (method $method) has no host on flutter_tester: a '
      "plugin's platform half never runs here. Either inject the value the "
      "app reads from it, or answer the channel in the folder's config: "
      'TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger'
      ".setMockMethodCallHandler(const MethodChannel('$channel'), "
      '(_) async => …).';
}

final _missing = RegExp(
  r'No implementation found for method (\S+) on channel (\S+?)\)?$',
  multiLine: true,
);
