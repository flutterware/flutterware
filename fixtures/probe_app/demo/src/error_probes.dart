import 'dart:async';

import 'package:material_ui/material_ui.dart';

// Deliberately not annotated. These are wrong on purpose, and the CI audit of
// this package fails on anything wrong, so they are kept out of the catalog —
// `app/test/previews/rendered_with_errors_test.dart` declares them itself, by
// hand, with the annotation each would have carried.

/// Renders, and then reports an error nobody awaited.
///
/// The shape of a font package that starts a download from a text style
/// getter and rethrows when the fetch fails: under `flutter_test` every HTTP
/// request is answered with 400, so the first frame is drawn in the fallback
/// font and the failure lands a moment later, as an uncaught error. The
/// picture is fine and the error is real, and a lane that throws the picture
/// away because of the error has answered neither question.
Widget lateError() => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: Text('Rendered anyway', style: _remoteFont())),
);

TextStyle _remoteFont() {
  unawaited(_fetchFont());
  return const TextStyle(fontSize: 24);
}

Future<void> _fetchFont() async {
  await Future<void>.delayed(Duration.zero);
  throw Exception(
    'Failed to load font with url: https://fonts.invalid/remote.ttf',
  );
}

/// An entry that is fine, under a wrapper that is not.
///
/// The wrapper throws before anything is pumped, so there is no frame and
/// nothing reaches the error buffer — the failure is the only record, and
/// where it was thrown is what says the fault is in the theme and not in the
/// entry it was reported against.
Widget themed() => const Text('Never drawn', textDirection: TextDirection.ltr);

Widget brokenTheme(Widget child) =>
    throw StateError('the theme was asked for before it was configured');
